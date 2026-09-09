# CAP-14B: a console surface for the development host.
#
# THE DEFECT, recorded as TODO.txt #6: a frontend under `pweb dev` had no
# voice. Every console.log, console.warn and console.error, every uncaught
# throw and every unhandled rejection died inside the engine while the
# supervisor forwarded the host's own lines and nothing else, so a developer
# probed blind and paid extra iterations for what one line would have said.
#
# EVERY LEG DRIVES THE REAL THING. The console lines come from a real
# `pweb dev` session on a project the real `pweb create` scaffolded, running
# a real engine against a real `pweb://app` document; the release claim comes
# from a real `pweb build`; and the byte-identity claim comes from two real
# compiles of the shared host.
#
#   C0  the contract cross-checks, read back
#   R1  the RELEASE host's emitted object is byte-identical to one built with
#       every PWEB_DEV region physically removed - which, with C0's proof
#       that every CAP-14B addition is inside such a region, IS "the release
#       host is byte-untouched"
#   D1  a real dev session: the channel arms, the five console levels arrive
#       with their level, another console method is named in the text, an
#       object argument is rendered, an uncaught throw and an unhandled
#       rejection arrive WITH a source position
#   D2  a page cannot forge the acknowledgement: it logs one, and the CLI's
#       generation counter does not move
#   D3  a 10 000-line burst is BOUNDED and SAYS SO, the host is not
#       restarted and the loop keeps running
#   D4  a page calling the binding DIRECTLY, skipping the shim's own bound,
#       meets the host's ring instead
#   D5  console output survives a generation switch, with no re-install
#   D6  the membership-scoped listener sampler: zero listeners, members seen
#   B1  the RELEASE binary carries no console channel: no bind name, no shim
#   B2  PWEB_NATIVE_CSP is byte-identical in the development and release
#       binaries
#
# Emits build/cap14b/cli-<target>.json for the CAP-7F aggregation.
#
# Usage: pwsh test/cap14b/run_cap14b_gates.ps1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

. (Join-Path $repoRoot 'test/cap10d0/psargs.ps1')
. (Join-Path $repoRoot 'test/cap10c1/listener_members.ps1')

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$work = Join-Path $repoRoot 'build/cap14b'
New-Item -ItemType Directory -Force $work | Out-Null

$rows = [ordered]@{}
$failures = New-Object System.Collections.Generic.List[string]
function Row([string]$Key, [string]$Value) { $rows[$Key] = $Value }
function Require([bool]$Ok, [string]$Message) {
    if (-not $Ok) {
        $failures.Add($Message)
        Write-Host "GATE FAILURE: $Message"
    }
}
function Bool([bool]$B) { if ($B) { 'true' } else { 'false' } }
function TargetName {
    $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64'   { 'x86_64' }
        'Arm64' { 'arm64' }
        default { 'other' }
    }
    return "$os-$arch"
}
# READ A FILE A LIVE PROCESS IS STILL WRITING - the CAP-10C2 lesson:
# Start-Process -RedirectStandardError holds the file on Windows and
# ReadAllText throws a sharing violation while the child lives
function ReadLive([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = $null
    $sr = $null
    try {
        $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = [System.IO.StreamReader]::new($fs)
        return $sr.ReadToEnd()
    } catch {
        return ''
    } finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}
function ExtractCsp([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $needle = [System.Text.Encoding]::ASCII.GetBytes("default-src 'self'")
    $limit = $bytes.Length - $needle.Length
    for ($i = 0; $i -le $limit; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $needle.Length; $j++) {
            if ($bytes[$i + $j] -ne $needle[$j]) { $ok = $false; break }
        }
        if (-not $ok) { continue }
        $sb = New-Object System.Text.StringBuilder
        $k = $i
        while (($k -lt $bytes.Length) -and ($bytes[$k] -ge 0x20) -and
               ($bytes[$k] -le 0x7E)) {
            [void]$sb.Append([char]$bytes[$k]); $k++
        }
        return $sb.ToString()
    }
    return ''
}
function BytesContain([string]$Path, [string]$Text) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $needle = [System.Text.Encoding]::ASCII.GetBytes($Text)
    $limit = $bytes.Length - $needle.Length
    for ($i = 0; $i -le $limit; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $needle.Length; $j++) {
            if ($bytes[$i + $j] -ne $needle[$j]) { $ok = $false; break }
        }
        if ($ok) { return $true }
    }
    return $false
}

$target = TargetName
Row 'target' $target
Row 'console_surface_available' 'true'

# --- preconditions ----------------------------------------------------------
$sdk = Join-Path $repoRoot 'build/cap10b1/sdk'
$pweb = Join-Path $sdk "bin/pweb$exeSuffix"
Require (Test-Path -LiteralPath $pweb) `
    "precondition absent: $pweb -- run the CAP-10B1 SDK staging first"
# THE STAGED SOURCE MUST BE THIS CHECKOUT'S. A root staged before this shard
# cannot compile a development host that carries the channel, and the failure
# would arrive as `sdk_integrity_mismatch` or as a missing unit rather than as
# the thing that is really wrong
$stagedConsole = Join-Path $sdk 'share/pweb/src/webview/pweb.webview.devconsole.pas'
$localConsole = Join-Path $repoRoot 'src/webview/pweb.webview.devconsole.pas'
$staged = (Test-Path -LiteralPath $stagedConsole) -and
    ((Get-FileHash -LiteralPath $stagedConsole -Algorithm SHA256).Hash -ceq
     (Get-FileHash -LiteralPath $localConsole -Algorithm SHA256).Hash)
Row 'console_sdk_src_staged' (Bool $staged)
Require $staged ('the staged SDK root does not carry THIS checkout of ' +
    'src/webview/pweb.webview.devconsole.pas -- run ' +
    'test/cap10c2/build_cap10c2 (and re-package if the root carries a manifest)')
$pinnedPas2js = @('deps/pas2js/bin', 'deps/pas2js-linux/bin',
    'deps/pas2js-darwin/bin') |
    ForEach-Object { Join-Path $repoRoot $_ } |
    Where-Object { Test-Path -LiteralPath $_ }
if ($pinnedPas2js.Count -gt 0) {
    $env:PATH = (($pinnedPas2js -join [System.IO.Path]::PathSeparator) +
        [System.IO.Path]::PathSeparator + $env:PATH)
}
$pas2jsOnPath = $null -ne (Get-Command pas2js -ErrorAction SilentlyContinue)
Row 'cap14b_pas2js_on_path' (Bool $pas2jsOnPath)
Require $pas2jsOnPath `
    'pas2js is not on PATH and no pinned copy exists under deps/ -- the dev session cannot be measured'
if ($failures.Count -gt 0) {
    throw "CAP-14B preconditions FAILED: $($failures.Count)"
}

# --- C0: the contract cross-checks, read back -------------------------------
$contractsFile = Join-Path $work 'contracts.json'
Require (Test-Path -LiteralPath $contractsFile) `
    'build/cap14b/contracts.json is absent -- run test/cap14b/check_cap14b_contracts.ps1 first'
if (Test-Path -LiteralPath $contractsFile) {
    $c = Get-Content -LiteralPath $contractsFile -Raw | ConvertFrom-Json
    Row 'console_contracts' "$($c.verdict)"
    Row 'console_levels' "$($c.levels)"
    Row 'console_line_headroom' "$($c.line_headroom_bytes)"
    Row 'console_uses_count' "$($c.console_uses_count)"
    Row 'console_shim_sha256' "$($c.shim_sha256)"
    Require ("$($c.verdict)" -ceq 'PASS') `
        "the CAP-14B contract cross-checks report $($c.verdict)"
    # THE FOUR-TARGET INVARIANT of the dev-only claim, and the reason it is a
    # SOURCE property rather than a compiled one: every leg can read it, on
    # any machine, with no toolchain at all. The object comparison below is
    # its corroboration where a compiler will answer.
    Row 'console_host_markers_outside_dev' "$($c.host_markers_outside_pweb_dev)"
    Require ([int]"$($c.host_markers_outside_pweb_dev)" -eq 0) `
        'a CAP-14B addition to the release host sits outside a PWEB_DEV conditional'
}

# --- R1: the release host's emitted object, with and without the seam -------
# EVERY PWEB_DEV REGION IS PHYSICALLY REMOVED and the result is compiled
# beside the real one. If the two objects differ, a conditional region reached
# a release compile - which is the only way "byte-untouched" can be false once
# C0 has proved every addition is inside one. It needs no git history, so it
# answers the same on a shallow checkout as on a full one.
$hostSrc = Join-Path $repoRoot 'src/webview/pweb.webview.host.pas'
$baseDir = Join-Path $work 'base'
if (Test-Path -LiteralPath $baseDir) { Remove-Item -Recurse -Force -LiteralPath $baseDir }
New-Item -ItemType Directory -Force $baseDir | Out-Null
$stripped = New-Object System.Collections.Generic.List[string]
$depth = 0
$devDepth = -1
$removed = 0
foreach ($line in [System.IO.File]::ReadLines($hostSrc)) {
    $opens = ([regex]::Matches($line, '\{\$\s*if(n?def|)\b')).Count
    $closes = ([regex]::Matches($line, '\{\$\s*endif\b')).Count
    $isDevOpen = $line -match '\{\$\s*ifdef\s+PWEB_DEV\s*\}'
    if ($isDevOpen -and ($devDepth -lt 0)) { $devDepth = $depth }
    $depth += $opens
    if ($devDepth -ge 0) { $removed++ } else { $stripped.Add($line) }
    $depth -= $closes
    if (($devDepth -ge 0) -and ($depth -le $devDepth)) { $devDepth = -1 }
}
$strippedPath = Join-Path $baseDir 'pweb.webview.host.pas'
[System.IO.File]::WriteAllLines($strippedPath, $stripped,
    [System.Text.UTF8Encoding]::new($false))
Row 'host_pweb_dev_lines_removed' "$removed"
Require ($removed -gt 0) 'the stripper removed no PWEB_DEV line at all'

# THE TARGET IS SELECTED THE WAY PWebCliFpcCommand SELECTS IT, and for the
# same reason: Windows is the one platform whose compiler ships more than one
# target and whose default is not necessarily this one (this dev host's
# default `fpc` is the i386 one). Everywhere else the compiler's own default
# is the target, exactly as a real `pweb build` leaves it. `-WM` is not
# mirrored because nothing here is LINKED: both compiles omit it, so the
# comparison is between two objects built the same way.
$targetFlags = if ($IsWindows) { @('-Px86_64', '-Twin64') } else { @() }
$fpcOs = (& fpc @targetFlags -iTO 2>$null)
$fpcCpu = (& fpc @targetFlags -iTP 2>$null)
if ($fpcOs) { $fpcOs = "$fpcOs".Trim().ToLowerInvariant() }
if ($fpcCpu) { $fpcCpu = "$fpcCpu".Trim().ToLowerInvariant() }
Row 'host_compile_target' "$fpcCpu-$fpcOs"
$platformDir = if ($IsWindows) { 'src/platform/windows' }
    elseif ($IsMacOS) { 'src/platform/macos' } else { 'src/platform/linux' }
$statics = "deps/mormot2/static/$fpcCpu-$fpcOs"
$common = $targetFlags + @('-MObjFPC', '-Sh', '-B', '-Fusrc/lib', '-Fusrc/rpc',
    '-Fusrc/security', '-Fusrc/webview', '-Fusrc/assets',
    ('-Fu' + $platformDir), '-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
    '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt', ('-Fl' + $statics))
function CompileHost([string]$Source, [string]$UnitDir) {
    if (Test-Path -LiteralPath $UnitDir) { Remove-Item -Recurse -Force -LiteralPath $UnitDir }
    New-Item -ItemType Directory -Force $UnitDir | Out-Null
    $log = Join-Path $work 'hostcompile.log'
    $p = Start-PWebProcess -FilePath 'fpc' `
        -ArgumentList (@("-FU$UnitDir") + $common + @($Source)) `
        -Wait -PassThru -NoNewWindow -WorkingDirectory $repoRoot `
        -RedirectStandardOutput $log -RedirectStandardError (Join-Path $work 'hostcompile.err')
    return $p.ExitCode
}
$objA = Join-Path $work 'objA'
$objB = Join-Path $work 'objB'
$ecA = CompileHost $strippedPath $objA
$ecB = CompileHost $hostSrc $objB
Row 'host_compile_stripped_exit' "$ecA"
Row 'host_compile_shard_exit' "$ecB"
$oA = Join-Path $objA 'pweb.webview.host.o'
$oB = Join-Path $objB 'pweb.webview.host.o'
# A COMPILER THAT COULD NOT ANSWER IS `not_applicable`, NOT A RED LEG - the
# CAP-14A lesson, learned on hosted run 34316904346 where three POSIX legs
# went red for a claim about a directory rather than about a binary. This leg
# compiles a unit whose platform body differs per target and needs that
# target's toolchain to be complete; where it is, the comparison is the
# strongest form of "byte-untouched" there is, and where it is not, the
# four-target invariant is still `console_host_markers_outside_dev`, which is
# a source property every leg can read with no toolchain at all.
if (($ecA -ne 0) -or ($ecB -ne 0)) {
    Row 'release_host_object_unchanged' 'not_applicable'
    Row 'release_host_object_sha256' 'not_applicable'
    Write-Host ('[cap14b] the release host did not compile on this target ' +
        "($ecA / $ecB); the object comparison is not_applicable and the " +
        'source-level invariant carries the claim')
} else {
    $same = (Test-Path -LiteralPath $oA) -and (Test-Path -LiteralPath $oB) -and
        ((Get-FileHash -LiteralPath $oA -Algorithm SHA256).Hash -ceq
         (Get-FileHash -LiteralPath $oB -Algorithm SHA256).Hash)
    Row 'release_host_object_unchanged' (Bool $same)
    Row 'release_host_object_sha256' $(if (Test-Path -LiteralPath $oB) {
        (Get-FileHash -LiteralPath $oB -Algorithm SHA256).Hash.ToLowerInvariant() }
        else { 'unmeasured' })
    Require $same ('the release host emits DIFFERENT bytes with and without ' +
        'the PWEB_DEV regions: the release host is not byte-untouched')
}

# --- the project, and its two probes ----------------------------------------
$stage = Join-Path $work 'gatestage'
if (Test-Path -LiteralPath $stage) { Remove-Item -Recurse -Force -LiteralPath $stage }
New-Item -ItemType Directory -Force $stage | Out-Null
$cwd = Join-Path $work 'gatecwd'
New-Item -ItemType Directory -Force $cwd | Out-Null
function RunCli([string[]]$CliArgs, [string]$WorkDir, [int]$TimeoutMs = 900000) {
    $so = Join-Path $work 'cli-stdout.txt'
    $se = Join-Path $work 'cli-stderr.txt'
    foreach ($f in @($so, $se)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -Force -LiteralPath $f }
    }
    $p = Start-PWebProcess -FilePath $pweb -ArgumentList $CliArgs -PassThru `
        -NoNewWindow -WorkingDirectory $WorkDir `
        -RedirectStandardOutput $so -RedirectStandardError $se
    if (-not $p.WaitForExit($TimeoutMs)) { $p.Kill($true); $p.WaitForExit(30000) | Out-Null }
    return [pscustomobject]@{
        Code = $p.ExitCode
        Out  = if (Test-Path -LiteralPath $so) { [System.IO.File]::ReadAllText($so) } else { '' }
        Err  = if (Test-Path -LiteralPath $se) { [System.IO.File]::ReadAllText($se) } else { '' }
    }
}
$r = RunCli @('create', 'demo', '--ui', 'pas2js', '--bundle-id', 'com.example.demo') $stage
Require ($r.Code -eq 0) "scaffolding the pas2js project failed: $($r.Code) $($r.Err.Trim())"
$proj = Join-Path $stage 'demo'
$entry = @(Get-ChildItem -LiteralPath (Join-Path $proj 'frontend/src') -File `
    -Filter '*app.lpr')
Require ($entry.Count -eq 1) 'the scaffold produced no single frontend entry point'
$entryPath = $entry[0].FullName
$entryClean = [System.IO.File]::ReadAllText($entryPath)

# THE PROBE IS PASCAL WITH ONE asm BLOCK, so it compiles into assets/app.js
# and reaches the page as a same-origin script - the only shape CAP-14A
# accepts, and the only one that gives a real source position
function WriteProbe([string]$Body) {
    $text = $entryClean.Replace("begin`n  RunApp;", "begin`n  RunApp;`n  asm`n$Body`n  end;")
    if ($text -ceq $entryClean) {
        # the scaffold may carry CRLF; do it again over the other shape
        $text = $entryClean.Replace("begin`r`n  RunApp;",
            "begin`r`n  RunApp;`r`n  asm`r`n$Body`r`n  end;")
    }
    [System.IO.File]::WriteAllText($entryPath, $text,
        (New-Object System.Text.UTF8Encoding($false)))
    return ($text -cne $entryClean)
}
$PROBE1 = @'
    console.log('C14B gen1 log', {a:1,b:[2,3]});
    console.info('C14B gen1 info');
    console.warn('C14B gen1 warn');
    console.error('C14B gen1 error');
    console.debug('C14B gen1 debug');
    console.trace('C14B gen1 trace');
    console.log('C14B FORGE: generation 987 loaded');
    setTimeout(function () { null.boom(); }, 400);
    setTimeout(function () { Promise.reject(new Error('C14B gen1 rejection')); }, 600);
'@
$PROBE2 = @'
    console.log('C14B gen2 log');
    var US = String.fromCharCode(31), NL = String.fromCharCode(10);
    var recs = [];
    for (var r = 0; r < 8; r++) recs.push('log' + US + 'log' + US + US + 'C14B direct ' + r);
    var payload = btoa(recs.join(NL));
    setTimeout(function () {
      for (var i = 0; i < 4000; i++) { try { window.__pweb_dev_console(payload); } catch (e) {} }
    }, 300);
    setTimeout(function () {
      for (var j = 0; j < 10000; j++) console.log('C14B burst ' + j);
    }, 800);
'@
Require (WriteProbe $PROBE1) 'the gen-1 probe could not be written into the entry point'

# --- the dev session --------------------------------------------------------
$devDir = Join-Path $proj "dist/$target/dev"
$do = Join-Path $work 'gate-dev-stdout.txt'
$de = Join-Path $work 'gate-dev-stderr.txt'
foreach ($f in @($do, $de)) {
    if (Test-Path -LiteralPath $f) { Remove-Item -Force -LiteralPath $f }
}
$dev = Start-PWebProcess -FilePath $pweb `
    -ArgumentList @('dev', '--project', $proj) -PassThru -NoNewWindow `
    -WorkingDirectory $cwd -RedirectStandardOutput $do -RedirectStandardError $de
function Seen { return (ReadLive $de) + "`n" + (ReadLive $do) }
function WaitFor([string]$Pattern, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while (((Get-Date) -lt $deadline) -and (-not $dev.HasExited)) {
        $s = Seen
        if ($s -match $Pattern) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return ((Seen) -match $Pattern)
}
$ready1 = WaitFor '(?m)^pweb: generation 1 ready' 900
Row 'console_gen1_ready' (Bool $ready1)
Require $ready1 'the development loop never published generation 1'
$armed = WaitFor '(?m)^app: .*: console armed' 240
Row 'console_armed' (Bool $armed)
Require $armed 'the console channel never reported that it armed'
$seen = Seen
$hostPidBefore = if ($seen -match '(?m)^pweb: started pid (\d+)') { $Matches[1] } else { '' }
Row 'console_host_pid_seen' (Bool ($hostPidBefore -ne ''))

# D6: the listener sample, while the session is really running
if ($hostPidBefore -ne '') {
    # the CAP-10C1 sampler, typed by OWNER IMAGE exactly as CAP-10C2 uses it:
    # `listenMax` is the HOST-owned maximum, and a browser helper's own socket
    # is recorded beside it rather than counted as the host's (ledger 11B-13)
    $membersSeen = 0
    $listenMax = 0
    $browserMax = 0
    $unknownMax = 0
    $detail = @()
    for ($pass = 0; $pass -lt 6; $pass++) {
        $typed = Get-PWebTypedListeners -RootPid ([int]$hostPidBefore)
        if ($typed.MembersSeen -gt $membersSeen) { $membersSeen = $typed.MembersSeen }
        if ($typed.Host_ -gt $listenMax) { $listenMax = $typed.Host_ }
        if ($typed.Browser -gt $browserMax) { $browserMax = $typed.Browser }
        if ($typed.Unknown -gt $unknownMax) { $unknownMax = $typed.Unknown }
        foreach ($d in $typed.Detail) {
            if (-not ($detail -contains $d)) { $detail += $d }
        }
        Start-Sleep -Milliseconds 700
    }
    Row 'console_listener_sampler_scope' (Get-PWebSamplerScope)
    Row 'console_listener_members_seen' "$membersSeen"
    Row 'console_listener_members_max' "$listenMax"
    Row 'console_listener_owner_browser' "$browserMax"
    Row 'console_listener_owner_unknown' "$unknownMax"
    Row 'console_listener_detail' $(if ($detail.Count -eq 0) { 'none' } else { ($detail -join ' | ') })
    foreach ($d in $detail) { Write-Host "[cap14b] sampled listener: $d" }
    Require ($membersSeen -gt 0) 'the listener sampler saw no member, so its zero says nothing'
    Require ($listenMax -eq 0) "the dev session owned $listenMax host listening socket(s)"
}

# D1: the levels, the method, the object and the two positions
$ok = WaitFor 'console rejection @' 240
$seen = Seen
$lines = @($seen -split "`r?`n" | Where-Object { $_ -match '^app: .*: console ' })
Row 'console_lines_gen1' "$($lines.Count)"
$levelsSeen = @()
foreach ($lv in 'log', 'info', 'warn', 'error', 'debug') {
    if ($seen -match [regex]::Escape("console $lv" + ": C14B gen1 $lv")) {
        $levelsSeen += $lv
    }
}
Row 'console_levels_seen' ($levelsSeen -join ',')
Require ($levelsSeen.Count -eq 5) `
    ("only $($levelsSeen.Count)/5 console levels arrived: " + ($levelsSeen -join ','))
Row 'console_method_named' (Bool ($seen -match 'console log: trace C14B gen1 trace'))
Require ($seen -match 'console log: trace C14B gen1 trace') `
    'a console method whose name is not its level was not named in the text'
Row 'console_object_rendered' (Bool ($seen.Contains('{"a":1,"b":[2,3]}')))
Require ($seen.Contains('{"a":1,"b":[2,3]}')) `
    'an object argument was not rendered'
$uncaught = [regex]::Match($seen,
    '(?m)^app: .*: console uncaught @(pweb://app/[^:]+:\d+:\d+): ')
$rejection = [regex]::Match($seen,
    '(?m)^app: .*: console rejection @(\S+:\d+:\d+): ')
Row 'console_uncaught_position' $(if ($uncaught.Success) { $uncaught.Groups[1].Value } else { 'absent' })
Row 'console_rejection_position' $(if ($rejection.Success) { $rejection.Groups[1].Value } else { 'absent' })
Row 'console_error_position' (Bool ($uncaught.Success -and $rejection.Success))
Require $uncaught.Success 'an uncaught throw arrived without a source position'
Require $rejection.Success 'an unhandled rejection arrived without a source position'

# D2: the forged acknowledgement
$forgePrinted = $seen -match 'console log: C14B FORGE: generation 987 loaded'
$genLines = @([regex]::Matches($seen, '(?m)^pweb: generation (\d+) ready') |
    ForEach-Object { [int]$_.Groups[1].Value })
$maxGen = if ($genLines.Count -gt 0) { ($genLines | Measure-Object -Maximum).Maximum } else { 0 }
Row 'console_forged_ack_printed' (Bool $forgePrinted)
Row 'console_forged_ack_ignored' (Bool ($maxGen -lt 987))
Row 'console_generations_after_forgery' "$maxGen"
Require $forgePrinted 'the forged acknowledgement was not printed as ordinary text'
Require ($maxGen -lt 987) `
    "a page-authored line moved the CLI's generation counter to $maxGen"
Require (Test-Path -LiteralPath (Join-Path $devDir 'gen-1/app.pwb')) `
    'the forged acknowledgement cost the live generation'

# D3 / D4 / D5: the switch, the burst and the direct calls
Require (WriteProbe $PROBE2) 'the gen-2 probe could not be written into the entry point'
$ready2 = WaitFor '(?m)^pweb: generation 2 ready' 900
Row 'console_gen2_ready' (Bool $ready2)
Require $ready2 'the development loop never published generation 2'
$loaded2 = WaitFor '(?m)^app: .*: generation 2 loaded' 240
Row 'console_gen2_loaded' (Bool $loaded2)
Require $loaded2 'the host never acknowledged generation 2'
$survived = WaitFor 'console log: C14B gen2 log' 240
Row 'console_survives_generation_switch' (Bool $survived)
Require $survived 'console output did not survive the generation switch'
# the burst needs its own settling time: the page-side flush is bounded per
# interval by construction, so the lines arrive over several seconds
$dropped = WaitFor 'console dropped: \d+ \(page\)' 240
Start-Sleep -Seconds 15
$seen = Seen
$burstLines = @([regex]::Matches($seen, 'C14B burst ')).Count
$directLines = @([regex]::Matches($seen, 'C14B direct ')).Count
$pageDrop = [regex]::Match($seen, 'console dropped: (\d+) \(page\)')
$hostDrop = [regex]::Match($seen, 'console dropped: (\d+) \(host\)')
Row 'console_burst_offered' '10000'
Row 'console_burst_emitted' "$burstLines"
Row 'console_page_dropped' $(if ($pageDrop.Success) { $pageDrop.Groups[1].Value } else { '0' })
Row 'console_direct_emitted' "$directLines"
Row 'console_host_dropped' $(if ($hostDrop.Success) { $hostDrop.Groups[1].Value } else { '0' })
Row 'console_bound_enforced' (Bool (($burstLines -lt 10000) -and $pageDrop.Success))
Require ($burstLines -lt 10000) `
    "a 10 000-line burst emitted $burstLines lines: the bound did not hold"
Require $pageDrop.Success `
    'the channel bounded the burst without saying how many it dropped'
Row 'console_host_ring_engaged' (Bool $hostDrop.Success)
Require ($directLines -gt 0) `
    'a page calling the binding directly produced no line at all'
# WHETHER THE HOST RING OVERFLOWS IS A RACE, and it is deliberately NOT
# required here. MEASURED: windows-x86_64 dropped ~30 700 of 32 000 records
# while linux-x86_64 dropped 24, because the writer thread's drain and the
# GUI thread's dispatches run concurrently and whichever machine is faster
# decides. Requiring the overflow would be requiring one machine's timing.
# The ring's behaviour is pinned where it is DETERMINISTIC - the headless
# `RingBound` case drives the real ring and the real writer path past
# capacity and asserts the exact emitted count and the one notice - and what
# this leg requires is the property a race cannot fake: 4 000 direct calls
# skipping the shim's own bound produce lines, do not stall the loop, and do
# not restart the host.
Require (-not $dev.HasExited) 'the burst stopped the development loop'
$seen = Seen
$hostPidAfter = if ($seen -match '(?m)^pweb: started pid (\d+)') { $Matches[1] } else { '' }
Row 'console_host_pid_unchanged' `
    (Bool (($hostPidBefore -ne '') -and ($hostPidBefore -ceq $hostPidAfter)))
Require ($hostPidBefore -ceq $hostPidAfter) `
    "the host was restarted during the console legs: $hostPidBefore -> $hostPidAfter"
# no ANSI reaches a redirected stream, on this channel like every other
Row 'console_ansi_seen' (Bool ($seen.Contains("`e")))
Require (-not $seen.Contains("`e")) 'an ANSI escape reached a redirected stream'

if (-not $dev.HasExited) { $dev.Kill($true) }
$dev.WaitForExit(30000) | Out-Null

# --- B1 / B2: the release binary --------------------------------------------
[System.IO.File]::WriteAllText($entryPath, $entryClean,
    (New-Object System.Text.UTF8Encoding($false)))
$r = RunCli @('build', '--project', $proj) $cwd
Row 'console_release_build_exit' "$($r.Code)"
Require ($r.Code -eq 0) "the release build failed: $($r.Code) $($r.Err.Trim())"
$release = Join-Path $proj "dist/$target/release"
$relExe = @(Get-ChildItem -LiteralPath $release -Recurse -File -Force |
    Where-Object { ($_.Extension -eq '.exe') -or ($_.Extension -eq '') } |
    Sort-Object Length -Descending | Select-Object -First 1)
$devExe = @(Get-ChildItem -LiteralPath (Join-Path $devDir 'app') -Recurse -File -Force |
    Where-Object { ($_.Extension -eq '.exe') -or ($_.Extension -eq '') } |
    Sort-Object Length -Descending | Select-Object -First 1)
Require ($relExe.Count -eq 1) 'no release binary was produced'
Require ($devExe.Count -eq 1) 'no development binary survived the session'
if (($relExe.Count -eq 1) -and ($devExe.Count -eq 1)) {
    $relHasBind = BytesContain $relExe[0].FullName '__pweb_dev_console'
    $devHasBind = BytesContain $devExe[0].FullName '__pweb_dev_console'
    $relHasShim = BytesContain $relExe[0].FullName '__pwebDevConsole__'
    $devHasShim = BytesContain $devExe[0].FullName '__pwebDevConsole__'
    $relHasDevArg = BytesContain $relExe[0].FullName '--pweb-dev-root='
    Row 'release_console_channel' $(if ($relHasBind -or $relHasShim) { 'present' } else { 'absent' })
    Row 'dev_console_channel' $(if ($devHasBind -and $devHasShim) { 'present' } else { 'absent' })
    Row 'release_dev_argument' $(if ($relHasDevArg) { 'present' } else { 'absent' })
    Require (-not $relHasBind) 'the RELEASE binary carries the console bind name'
    Require (-not $relHasShim) 'the RELEASE binary carries the console shim'
    Require (-not $relHasDevArg) 'the RELEASE binary carries the development argument'
    Require ($devHasBind -and $devHasShim) `
        'the DEVELOPMENT binary does not carry the channel it is supposed to'
    $cspRel = ExtractCsp $relExe[0].FullName
    $cspDev = ExtractCsp $devExe[0].FullName
    Row 'console_dev_csp' $cspDev
    Row 'dev_csp_equals_release' (Bool (($cspRel -ne '') -and ($cspRel -ceq $cspDev)))
    Require ($cspRel -ne '') 'no CSP could be read from the release binary'
    Require ($cspRel -ceq $cspDev) `
        'PWEB_NATIVE_CSP is not byte-identical in the two binaries'
    foreach ($banned in 'ws:', 'wss:', 'localhost', '127.0.0.1', 'http:') {
        Require (-not $cspDev.Contains($banned)) `
            "the development CSP contains '$banned'"
    }
}
# --- D7: the same channel, on a REAL generated React project ----------------
# The channel is the HOST's, not the bundle's, so the frontend kind changes no
# code path - which is exactly why this leg is worth running rather than
# assuming: a Vite-built page is a different document, a different script
# shape and a different `Error.stack`, and "it works for Pas2JS" says nothing
# about any of them. It needs the node toolchain, so it records
# `skipped_no_node` where there is none rather than inventing a verdict.
$nodeOk = ($null -ne (Get-Command node -ErrorAction SilentlyContinue)) -and
    ($null -ne (Get-Command npm -ErrorAction SilentlyContinue))
Row 'react_leg' $(if ($nodeOk) { 'ran' } else { 'skipped_no_node' })
# the rows exist on every leg whether or not it ran, so the aggregator can
# REQUIRE them present and a skipped leg says so instead of going missing
Row 'react_console_armed' 'absent'
Row 'react_console_levels_seen' 'absent'
Row 'react_console_uncaught_position' 'absent'
Row 'react_console_rejection_position' 'absent'
Row 'react_console_error_position' 'absent'
if ($nodeOk) {
    $r = RunCli @('create', 'reactdemo', '--ui', 'react',
        '--bundle-id', 'com.example.reactdemo') $stage
    Require ($r.Code -eq 0) "scaffolding the react project failed: $($r.Code) $($r.Err.Trim())"
    $rproj = Join-Path $stage 'reactdemo'
    $app = Join-Path $rproj 'frontend/src/App.tsx'
    Require (Test-Path -LiteralPath $app) 'the react scaffold produced no App.tsx'
    $appText = [System.IO.File]::ReadAllText($app)
    $probe = @'

// CAP-14B console probe - appended by test/cap14b/run_cap14b_gates.ps1
console.log('C14B react log', { a: 1 });
console.info('C14B react info');
console.warn('C14B react warn');
console.error('C14B react error');
console.debug('C14B react debug');
setTimeout(() => { (null as unknown as { boom: () => void }).boom(); }, 400);
setTimeout(() => { Promise.reject(new Error('C14B react rejection')); }, 600);
'@
    [System.IO.File]::WriteAllText($app, $appText + $probe,
        (New-Object System.Text.UTF8Encoding($false)))
    $rdo = Join-Path $work 'gate-react-stdout.txt'
    $rde = Join-Path $work 'gate-react-stderr.txt'
    foreach ($f in @($rdo, $rde)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -Force -LiteralPath $f }
    }
    $rdev = Start-PWebProcess -FilePath $pweb `
        -ArgumentList @('dev', '--project', $rproj) -PassThru -NoNewWindow `
        -WorkingDirectory $cwd -RedirectStandardOutput $rdo -RedirectStandardError $rde
    $deadline = (Get-Date).AddSeconds(1500)
    $rseen = ''
    while (((Get-Date) -lt $deadline) -and (-not $rdev.HasExited)) {
        $rseen = (ReadLive $rde) + "`n" + (ReadLive $rdo)
        if ($rseen -match 'console rejection @') { break }
        Start-Sleep -Milliseconds 1000
    }
    $rseen = (ReadLive $rde) + "`n" + (ReadLive $rdo)
    if (-not $rdev.HasExited) { $rdev.Kill($true) }
    $rdev.WaitForExit(30000) | Out-Null
    $rlevels = @()
    foreach ($lv in 'log', 'info', 'warn', 'error', 'debug') {
        if ($rseen -match [regex]::Escape("console $lv" + ": C14B react $lv")) {
            $rlevels += $lv
        }
    }
    $rUncaught = [regex]::Match($rseen,
        '(?m)^app: .*: console uncaught @(pweb://app/[^:]+:\d+:\d+): ')
    $rRejection = [regex]::Match($rseen,
        '(?m)^app: .*: console rejection @(\S+:\d+:\d+): ')
    Row 'react_console_rejection_position' $(if ($rRejection.Success) { $rRejection.Groups[1].Value } else { 'absent' })
    Row 'react_console_armed' (Bool ($rseen -match '(?m)^app: .*: console armed'))
    Row 'react_console_levels_seen' ($rlevels -join ',')
    Row 'react_console_uncaught_position' $(if ($rUncaught.Success) { $rUncaught.Groups[1].Value } else { 'absent' })
    Row 'react_console_error_position' (Bool ($rUncaught.Success -and $rRejection.Success))
    Require ($rseen -match '(?m)^app: .*: console armed') `
        'the console channel never armed in the react session'
    Require ($rlevels.Count -eq 5) `
        ("only $($rlevels.Count)/5 console levels arrived from the react page: " +
         ($rlevels -join ','))
    Require ($rUncaught.Success -and $rRejection.Success) `
        'a react page error arrived without a source position'
}

# THE MECHANISM, typed per target, and it is deliberately ONE value: the
# three engine-native alternatives were measured and refused (dev-contract
# §7b), and one mechanism on four targets is one line shape, one bound and
# one gate
Row 'console_mechanism' 'webview_init_user_script+webview_bind'

# --- the record -------------------------------------------------------------
Row 'cap14b_gates' $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
$json = ($rows | ConvertTo-Json -Depth 3)
$recordFile = Join-Path $work "cli-$target.json"
[System.IO.File]::WriteAllText($recordFile, ($json -replace "`r`n", "`n") + "`n",
    (New-Object System.Text.UTF8Encoding($false)))
Write-Host ''
foreach ($k in $rows.Keys) { Write-Host ("  {0,-38} {1}" -f $k, $rows[$k]) }
Write-Host ''
Write-Host "[cap14b] record written to $recordFile"
if ($failures.Count -gt 0) {
    Write-Host "CAP-14B GATES FAILED ($($failures.Count))"
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}
Write-Host 'CAP14B_GATES_PASS the development host has a console surface'
exit 0
