# CAP-15A: the outbound-network measurement, Windows/WebView2.
#
# Runs the SAME probe twice in a real window:
#
#   baseline  netprobe compiled against the SHIPPED pweb.navigation.policy
#             (connect-src 'self'), which is the product as it stands;
#   widened   netprobe compiled against a GENERATED shim of that unit whose
#             connect-src also names the probe server's origin A.
#
# The shim is produced HERE, by one exact substitution, and lives only under
# build/. Nothing widened is ever committed: the repository keeps the
# substitution rule, and a reader can see that the two binaries differ by one
# token of one constant and nothing else. `-B` on both builds so no .ppu from
# the other mode can survive into a run.
#
# The probe server (node, no dependencies) is restarted between the two runs
# so each mode gets a clean JSONL request log. That log is the independent
# witness: the page can misreport, and a no-cors request is unreadable to it,
# but a request that reached a socket is in the log.
#
# Writes, all under build/cap15a/:
#   windows-x86_64-baseline.json / -widened.json   the host reports
#   requests-<target>-baseline.jsonl / -widened.jsonl   the server's witness
#   summary-windows-x86_64.json                    the joined verdict
#
# Usage: pwsh test/cap15a/run_cap15a.ps1 [-PublicHttps <url>]
param(
    [string]$PublicHttps = '',
    [int]$PortA = 41597,
    [int]$PortB = 41598
)
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot
New-Item -ItemType Directory -Force build/cap15a | Out-Null
$work = (Resolve-Path build/cap15a).Path
$target = 'windows-x86_64'

foreach ($pre in 'build/webview-dist/webview.dll',
                 'test/cap15a/netprobe.pas',
                 'test/cap15a/probe_server.js',
                 'test/cap15a/fixture/index.html',
                 'test/cap15a/fixture/assets/probe.js',
                 'src/security/pweb.navigation.policy.pas') {
    if (-not (Test-Path $pre)) { throw "missing precondition: $pre" }
}
$node = (Get-Command node -ErrorAction SilentlyContinue)
if (-not $node) { throw 'node is required for the CAP-15A probe server' }

# THE GUARDED RECURSIVE DELETE, Windows half (deferred-work 15A-13). The POSIX
# sibling routes through tools/pwebrmtree.sh, which ledger 7M0-6 introduced
# because nothing validated a delete target first and an empty variable turns
# a removal of "$work/fpc-baseline" into a removal of somewhere else entirely.
# There is no PowerShell equivalent of that helper in this repository and this
# script is not the place to invent a convention thirty other test scripts do
# not follow - so the rule is applied locally, to the two paths this file
# actually deletes, and pinned by test/backlog/check_backlog.ps1 as 15A-13.
#
# It refuses in the same order as pweb_rm_tree: an empty target, a '..' path
# component, a target that does not resolve under the allowed root, and the
# allowed root itself. The comparison is on resolved full paths with a
# trailing separator on both sides, so C:\...\buildkit can never pass as
# inside C:\...\build. An ABSENT target is a no-op and not a refusal, for the
# same reason it is there: every caller deletes and immediately recreates, and
# on a fresh checkout there is nothing to delete yet.
$buildRoot = (Resolve-Path (Join-Path $repoRoot 'build')).Path
function Assert-UnderBuildRoot([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'refusing to delete: empty target path'
    }
    if (('/' + ($Path -replace '\\', '/') + '/') -like '*/../*') {
        throw "refusing to delete: '..' path component in '$Path'"
    }
    $full = [System.IO.Path]::GetFullPath($Path)
    $rootSlash = $buildRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($rootSlash, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "refusing to delete '$full': outside '$buildRoot'"
    }
    if ($full.TrimEnd('\', '/') -eq $buildRoot.TrimEnd('\', '/')) {
        throw "refusing to delete the allowed root itself: '$full'"
    }
    return $full
}
function Remove-BuildTree([string]$Path) {
    $full = Assert-UnderBuildRoot $Path
    if (Test-Path -LiteralPath $full) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

# WAIT, do not merely check: WSL with mirrored networking shares the Windows
# loopback, so the sibling POSIX run's probe server can still hold the port for
# a moment. MEASURED on a Windows-then-Linux sequence.
function Assert-PortFree([int]$port) {
    for ($i = 0; $i -lt 40; $i++) {
        $l = $null
        try {
            $l = [System.Net.Sockets.TcpListener]::new(
                [System.Net.IPAddress]::Loopback, $port)
            $l.Start()
            return
        } catch {
            Start-Sleep -Milliseconds 250
        } finally {
            if ($l) { $l.Stop() }
        }
    }
    throw "port $port is still in use after 10s -- pass -PortA/-PortB"
}
Assert-PortFree $PortA
Assert-PortFree $PortB

# --- the widened shim: ONE substitution, asserted unique -------------------
$policySrc = 'src/security/pweb.navigation.policy.pas'
$shimDir = Join-Path $work 'shim'
New-Item -ItemType Directory -Force $shimDir | Out-Null
$policyText = [System.IO.File]::ReadAllText($policySrc)
# the Pascal literal, with its doubled quotes, exactly as the unit spells it
$needle = "'connect-src ''self''; "
$occurrences = ([regex]::Matches($policyText, [regex]::Escape($needle))).Count
if ($occurrences -ne 1) {
    throw ("the connect-src token appears $occurrences time(s) in $policySrc " +
           '-- the CAP-15A shim substitution is no longer exact')
}
$widened = "'connect-src ''self'' http://127.0.0.1:$PortA ws://127.0.0.1:$PortA"
if ($PublicHttps) {
    $u = [System.Uri]$PublicHttps
    $widened += " $($u.Scheme)://$($u.Authority)"
}
$widened += "; "
$shimText = $policyText.Replace($needle, $widened)
$shimPath = Join-Path $shimDir 'pweb.navigation.policy.pas'
[System.IO.File]::WriteAllText($shimPath, $shimText,
    [System.Text.UTF8Encoding]::new($false))
Write-Host "[CAP-15A] shim written: $shimPath"

# --- build ----------------------------------------------------------------
function Build-Probe([string]$mode) {
    $fpcDir = Join-Path $work "fpc-$mode"
    $binDir = Join-Path $work "bin-$mode"
    Remove-BuildTree $fpcDir
    Remove-BuildTree $binDir
    New-Item -ItemType Directory -Force $fpcDir, $binDir | Out-Null
    $shimArg = @()
    if ($mode -eq 'widened') { $shimArg = @("-Fu$shimDir") }
    $args = @(
        '-Px86_64', '-Twin64', '-MObjFPC', '-Sh', '-B',
        "-FU$fpcDir", "-FE$binDir"
    ) + $shimArg + @(
        '-Fusrc/lib', '-Fusrc/rpc', '-Fusrc/security', '-Fusrc/webview',
        '-Fusrc/assets', '-Futest/security', '-Fusrc/platform/windows',
        '-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
        '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt',
        '-Fudeps/mormot2/src/net',
        '-Fldeps/mormot2/static/x86_64-win64',
        'test/cap15a/netprobe.pas'
    )
    Write-Host "[CAP-15A] building $mode"
    $buildOut = (& fpc @args 2>&1 | Out-String)
    Set-Content -Path (Join-Path $work "build-$mode.log") -Value $buildOut
    if ($LASTEXITCODE -ne 0) {
        Write-Host $buildOut
        throw "netprobe.pas ($mode) compile FAILED"
    }
    Copy-Item build/webview-dist/webview.dll $binDir -Force
    return (Join-Path $binDir 'netprobe.exe')
}

$exes = @{}
foreach ($mode in 'baseline', 'widened') { $exes[$mode] = Build-Probe $mode }

# --- run ------------------------------------------------------------------
$env:PWEB_WEBVIEW_DLL = (Resolve-Path build/webview-dist/webview.dll).Path
$env:PWEB_CAP15A_PORT_A = "$PortA"
$env:PWEB_CAP15A_PORT_B = "$PortB"
$env:PWEB_CAP15A_PUBLIC_HTTPS = $PublicHttps

function Invoke-Mode([string]$mode, [string]$exe) {
    $log = Join-Path $work "requests-$target-$mode.jsonl"
    $srvOut = Join-Path $work "server-$mode.log"
    Remove-Item -Force -ErrorAction SilentlyContinue $log, $srvOut
    $srvErr = Join-Path $work "server-$mode.err.log"
    Remove-Item -Force -ErrorAction SilentlyContinue $srvErr
    # STDERR IS CAPTURED, not discarded: without it a probe server that dies on
    # a bad port, an EADDRINUSE or an uncaught throw leaves the fifteen-second
    # wait below to report "never reported PROBE_READY" and nothing at all
    # about why. The POSIX sibling gets this free by redirecting both streams
    # to one file.
    $srv = Start-Process -FilePath $node.Source -PassThru -NoNewWindow `
        -ArgumentList @('test/cap15a/probe_server.js', '--portA', "$PortA",
                        '--portB', "$PortB", '--log', $log) `
        -RedirectStandardOutput $srvOut -RedirectStandardError $srvErr
    try {
        $deadline = (Get-Date).AddSeconds(15)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            if ((Test-Path $srvOut) -and
                (Select-String -Path $srvOut -Pattern 'PROBE_READY' -Quiet)) {
                $ready = $true; break
            }
            # the POSIX sibling checks `kill -0` each pass for exactly this:
            # a server that has already exited will never become ready, and
            # burning the whole budget to say so hides the cause
            if ($srv.HasExited) {
                $why = ''
                if (Test-Path $srvErr) { $why = (Get-Content -Raw $srvErr).Trim() }
                throw ("the probe server exited $($srv.ExitCode) before reporting " +
                       "PROBE_READY -- $srvErr" + $(if ($why) { ": $why" } else { '' }))
            }
            Start-Sleep -Milliseconds 150
        }
        if (-not $ready) { throw 'the probe server never reported PROBE_READY' }
        Write-Host "[CAP-15A] probe server up; running $mode"
        Push-Location ([System.IO.Path]::GetTempPath())
        try {
            $out = & $exe 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally { Pop-Location }
        Set-Content -Path (Join-Path $work "run-$mode.log") -Value $out
        Write-Host $out
        return @{ exit = $code; out = $out }
    } finally {
        # THE WIRE LOG IS THE WITNESS, so the server is asked to stop before it
        # is made to. `Stop-Process -Force` delivers no signal a node handler
        # can run on Windows, so the SIGTERM/SIGINT flush in probe_server.js
        # never fires there and a trailing record can be lost - and a lost
        # record is indistinguishable from the refusal the graded row asserts.
        # The server exits on its own when its stdin closes; the force kill
        # stays as the last resort it always was.
        if ($srv -and -not $srv.HasExited) {
            try { $srv.CloseMainWindow() | Out-Null } catch { }
            if (-not $srv.WaitForExit(3000)) {
                Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
            }
        }
        if ((Test-Path $srvErr) -and (Get-Item $srvErr).Length -gt 0) {
            Write-Host "[CAP-15A] probe server stderr ($mode):"
            Get-Content $srvErr | ForEach-Object { Write-Host "    $_" }
        }
    }
}

$results = @{}
foreach ($mode in 'baseline', 'widened') {
    $results[$mode] = Invoke-Mode $mode $exes[$mode]
}

# --- join: the server log is the witness ----------------------------------
# ONE summarizer for both platforms (test/cap15a/summarize.js): the join is
# the evidence, and a second copy of it in PowerShell would be a second
# answer to one question. It writes summary-<target>.json and exits nonzero
# if the baseline invariant did not hold.
& $node.Source test/cap15a/summarize.js --work $work --target $target `
    --portA "$PortA" --portB "$PortB"
$summaryExit = $LASTEXITCODE

# THE WIDENED SHIM DOES NOT SURVIVE THE RUN. $shimDir holds a unit with the
# SAME NAME as the shipped policy and a deliberately weakened CSP. Nothing
# commits it, but leaving it in the tree means any later build that puts that
# directory on a unit path compiles a widened connect-src and says nothing.
# "Nothing widened is ever committed" was the claim; "nothing widened survives
# the run" is the stronger one, and it costs one line on each runner.
Remove-BuildTree $shimDir

foreach ($mode in 'baseline', 'widened') {
    Write-Host "[CAP-15A] ${mode}: netprobe exit $($results[$mode].exit)"
    if ($results[$mode].exit -ne 0) {
        throw "netprobe ($mode) exited $($results[$mode].exit)"
    }
}
if ($summaryExit -ne 0) { throw 'CAP-15A: the baseline invariant did not hold' }
Write-Host "[CAP-15A] summary: $(Join-Path $work "summary-$target.json")"
