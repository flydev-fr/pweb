# CAP-10C0: the supervision contract, cross-checked against the source.
#
# Checkout-only (plus the compiled unit set the CAP-10B1 build leaves): no
# build, no toolchain, no display, no network. Runs in every platform job
# and on any dev host.
#
# WHAT IT PINS, and why each rule is a rule:
#
#   1. THE BOUNDS ARE STATED ONCE. Every supervision limit is a constant in
#      pweb.cli.toolchain and a row in docs/supervision-contract.md, and the
#      two must agree - a bound nobody cross-checks is a number somebody
#      typed.
#   2. NO SHELL, AT THE LINK. The CLI's compiled unit set must not carry FPC's
#      `process` or `pipes` units any more: CAP-10C0 replaced TProcess with
#      the raw platform primitives, and a unit that crept back in would bring
#      its own command-line quoting with it. (The SOURCE sweep for shell
#      spellings lives in test/cap10a/check_cap10a_contracts.ps1 and covers
#      the new units automatically.)
#   3. NO NAME-BASED KILL, ANYWHERE IN THE CLI. Descendants are selected by
#      job / process-group MEMBERSHIP; the primitives that enumerate or kill
#      by NAME are absent by rule, so `taskkill /IM msedgewebview2.exe` can
#      never be written here even by accident.
#   4. THE RUNTIME DOES NOT CONSULT THE ENVIRONMENT FOR SECURITY. `pweb run`
#      hands its environment to the application unchanged, which is only
#      safe because nothing in the policy, navigation, bridge or host layers
#      reads one for a decision: the single permitted read is the host's
#      auto-close SMOKE bound.
#   5. `run` NEVER BUILDS. The run unit and the program's run path name no
#      tool, no probe and no package manager.
#   6. THE CAP-9 SHUTDOWN ORDER IS THE SOURCE ORDER. The teardown after
#      webview_run closes the binding, drains the scheduler, detaches the
#      guard, detaches the handler and destroys the webview - in that order -
#      and the POSIX stop helper enters that path through the SAME dispatch
#      the auto-close thread uses.
#   7. THE PARSER'S COMMAND SET IS CLOSED. CAP-10C0 pinned `dev` and `build`
#      absent because neither existed; CAP-10C2 and CAP-10D0 implemented
#      them, so the sweep now names commands no shard will ratify and
#      requires all five that exist. The rule never moved: the parser must
#      accept exactly what this build can perform.
#
# Emits build/cap10c0/contracts.json.
#
# Usage: pwsh test/cap10c0/check_cap10c0_contracts.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
$facts = [ordered]@{}
function Violation([string]$Text) { $violations.Add($Text) }

# code lines only: comments are where this repository explains what it
# refuses, and a sweep that could not tell a literal from its explanation
# would forbid the explanation
function Get-CodeLines([string]$Path) {
    $rows = New-Object System.Collections.Generic.List[object]
    $inBrace = $false
    $n = 0
    foreach ($raw in [System.IO.File]::ReadLines($Path)) {
        $n++
        $line = $raw
        if ($inBrace) {
            $close = $line.IndexOf('}')
            if ($close -lt 0) { continue }
            $line = $line.Substring($close + 1)
            $inBrace = $false
        }
        $out = ''
        $i = 0
        while ($i -lt $line.Length) {
            $c = $line[$i]
            if ($c -eq '{' -and ($i + 1 -ge $line.Length -or $line[$i + 1] -ne '$')) {
                $close = $line.IndexOf('}', $i)
                if ($close -lt 0) { $inBrace = $true; break }
                $i = $close + 1
                continue
            }
            if ($c -eq '/' -and $i + 1 -lt $line.Length -and $line[$i + 1] -eq '/') { break }
            if ($c -eq "'") {
                $end = $i + 1
                while ($end -lt $line.Length) {
                    if ($line[$end] -eq "'") {
                        if ($end + 1 -lt $line.Length -and $line[$end + 1] -eq "'") { $end += 2; continue }
                        break
                    }
                    $end++
                }
                $out += $line.Substring($i, [Math]::Min($end + 1, $line.Length) - $i)
                $i = $end + 1
                continue
            }
            $out += $c
            $i++
        }
        if ($out.Trim() -ne '') {
            $rows.Add([pscustomobject]@{ Number = $n; Text = $out })
        }
    }
    return $rows
}

function Read-PascalConst([string]$File, [string]$Name) {
    $m = [regex]::Match([System.IO.File]::ReadAllText($File),
        "(?m)^\s*$([regex]::Escape($Name))\s*=\s*(\d+)\s*;")
    if (-not $m.Success) { throw "$Name not found in $File" }
    return [int]$m.Groups[1].Value
}

# --- 1. the bounds, once ----------------------------------------------------
$toolchain = 'tools/pweb/pweb.cli.toolchain.pas'
$contract = 'docs/supervision-contract.md'
if (-not (Test-Path $contract)) { throw "missing $contract" }
$contractText = [System.IO.File]::ReadAllText($contract)
$bounds = [ordered]@{}
foreach ($name in 'PWEB_CLI_RUN_GRACE_MS', 'PWEB_CLI_RUN_KILL_MS',
                  'PWEB_CLI_RUN_STOP_RETRY_MS', 'PWEB_CLI_RUN_LINE_MAX',
                  'PWEB_CLI_RUN_DIAG_MAX', 'PWEB_CLI_RUN_DRAIN_PASSES',
                  'PWEB_CLI_RUN_DRAIN_POLL_MS', 'PWEB_CLI_PROBE_TIMEOUT_MS',
                  'PWEB_CLI_PROBE_MAX_BYTES') {
    $value = Read-PascalConst $toolchain $name
    $bounds[$name] = $value
    # the contract's table row: `| NAME | value |`
    if ($contractText -notmatch "(?m)^\|\s*``$([regex]::Escape($name))``\s*\|\s*$value\s*\|") {
        Violation "docs/supervision-contract.md does not carry $name = $value"
    }
}
$facts['bounds'] = $bounds

# --- 2. no shell at the link -------------------------------------------------
$cliUnits = 'build/cap10b1/cli-units'
if (Test-Path $cliUnits) {
    $linked = @(Get-ChildItem $cliUnits -File -Filter '*.ppu')
    if ($linked.Count -lt 5) {
        Violation "$cliUnits holds no compiled unit set -- run test/cap10b1/build_cap10b1 first"
    }
    foreach ($u in $linked) {
        if ($u.Name -match '^(process|pipes)\.ppu$') {
            Violation "the CLI still LINKS FPC's $($u.Name): the one execution path is not the only one"
        }
    }
    $facts['linked_units'] = $linked.Count
    $facts['links_fpc_process'] = [bool]@($linked | Where-Object { $_.Name -match '^(process|pipes)\.ppu$' }).Count
    foreach ($needed in 'pweb.cli.process.ppu', 'pweb.cli.run.ppu') {
        if (-not (Test-Path (Join-Path $cliUnits $needed))) {
            Violation "the CLI does not link $needed"
        }
    }
} else {
    Violation "$cliUnits is missing -- run test/cap10b1/build_cap10b1 first"
}

# --- 3. no name-based kill --------------------------------------------------
# (patterns are concatenated so this file cannot match its own source)
$killPatterns = @(
    ('Process32' + 'First'), ('Process32' + 'Next'), ('EnumPro' + 'cesses'),
    ('CreateToolhelp32' + 'Snapshot'), ('task' + 'kill'), ('Stop-Pro' + 'cess'),
    ('kill' + 'all'), ('pk' + 'ill'), ('pg' + 'rep'), ('Name=' + "'"),
    ('FindWindow' + 'W'), ('FindWindow' + 'A'), ('/proc/' + '*/comm')
)
$cliSources = @(Get-ChildItem tools/pweb -File -Filter '*.pas')
foreach ($src in $cliSources) {
    foreach ($row in (Get-CodeLines $src.FullName)) {
        foreach ($pat in $killPatterns) {
            if ($row.Text.Contains($pat)) {
                Violation ("NAME-BASED PROCESS PRIMITIVE: $($src.Name):$($row.Number): " +
                    $row.Text.Trim())
            }
        }
    }
}
# DERIVED from what the sweep found, never restated: the gate copies this
# into the evidence and the aggregate pins it
$facts['global_name_kill_present'] = [bool]@($violations | Where-Object { $_ -match '^NAME-BASED PROCESS PRIMITIVE' }).Count
# and the only kill verbs are the tree ones: TerminateJobObject, or a signal
# to a NEGATIVE pid (the group), plus the belt-and-braces on the child's own
# pid inside PWebCliChildKill
$platform = 'tools/pweb/pweb.cli.platform.pas'
$killLines = @(Get-CodeLines $platform | Where-Object {
    $_.Text -match 'FpKill\(' -or $_.Text -match 'TerminateProcess\(' -or
    $_.Text -match 'TerminateJobObject\(' })
foreach ($k in $killLines) {
    if ($k.Text -match 'FpKill\(\s*([^,]+),\s*SIG(KILL|TERM)') {
        $target = $Matches[1].Trim()
        if (($target -notmatch '^-Child\.Group$') -and ($target -ne 'Child.Pid') -and
            ($target -ne 'Pid')) {
            Violation "a signal aimed outside the tree: $platform`:$($k.Number): $($k.Text.Trim())"
        }
    }
    if ($k.Text -match 'TerminateProcess\(\s*([^,]+),') {
        $target = $Matches[1].Trim()
        if (($target -ne 'Child.Handle') -and ($target -ne 'pi.hProcess')) {
            Violation "TerminateProcess aimed outside the child: $platform`:$($k.Number): $($k.Text.Trim())"
        }
    }
}
$facts['kill_sites'] = $killLines.Count

# --- 4. the runtime does not consult the environment for security -----------
$envPattern = 'GetEnvironmentVariable|getenv\(|GetEnv\(|EnvW\(|environ\b'
$runtimeRoots = @('src/security', 'src/rpc', 'src/webview', 'src/assets')
$allowedEnv = @{ 'src/webview/pweb.webview.host.pas' = 'PWEB_HOST_AUTOCLOSE_ENV' }
$envReads = New-Object System.Collections.Generic.List[string]
foreach ($root in $runtimeRoots) {
    foreach ($f in (Get-ChildItem $root -Recurse -File -Include '*.pas', '*.inc')) {
        $rel = ($f.FullName.Substring($repoRoot.Length).TrimStart('\', '/')) -replace '\\', '/'
        foreach ($row in (Get-CodeLines $f.FullName)) {
            if ($row.Text -match $envPattern) {
                $envReads.Add("${rel}:$($row.Number)")
                if (-not $allowedEnv.ContainsKey($rel)) {
                    Violation "the runtime reads the environment: ${rel}:$($row.Number): $($row.Text.Trim())"
                } elseif ($row.Text -notmatch [regex]::Escape($allowedEnv[$rel])) {
                    Violation "an unratified environment read: ${rel}:$($row.Number): $($row.Text.Trim())"
                }
            }
        }
    }
}
$facts['runtime_env_reads'] = @($envReads)

# --- 5. run never builds ---------------------------------------------------
$toolPattern = "\b(npm|pas2js|vite|node|fpc|git)\b|PWebCliProbeTool|PWebCliResolveTool|PWebCliRunProbe|pweb\.cli\.probe|pweb\.cli\.doctor|pweb\.cli\.scaffold|pweb\.cli\.write"
foreach ($row in (Get-CodeLines 'tools/pweb/pweb.cli.run.pas')) {
    if ($row.Text -match $toolPattern) {
        Violation "pweb.cli.run names a tool or a build path: line $($row.Number): $($row.Text.Trim())"
    }
}
# the program's RunRun body: from its header to the next function
$programCode = (Get-CodeLines 'tools/pweb/pweb.pas' | ForEach-Object { $_.Text }) -join "`n"
$runBody = [regex]::Match($programCode, '(?s)function RunRun\(.*?\nfunction Main:')
if (-not $runBody.Success) { Violation 'RunRun not found in pweb.pas' }
elseif ($runBody.Value -match $toolPattern) {
    Violation 'the program''s run path names a tool, a probe or a build unit'
}
foreach ($absent in 'PWebCreateProject', 'PWebBuildPlan', 'PWebTplLoadPack') {
    if ($runBody.Success -and $runBody.Value.Contains($absent)) {
        Violation "the run path reaches the scaffold engine: $absent"
    }
}

# --- 6. the shutdown order and the helper's dispatch -------------------------
$hostFile = 'src/webview/pweb.webview.host.pas'
$hostCode = (Get-CodeLines $hostFile | ForEach-Object { $_.Text }) -join "`n"
$runIdx = $hostCode.IndexOf('WebViewCheck(webview_run(w)')
if ($runIdx -lt 0) { Violation 'webview_run not found in the host' }
else {
    $after = $hostCode.Substring($runIdx)
    $order = @('binding.Close', 'schedulerRef.Shutdown', 'navGuard.Detach',
               'assetHandler.Detach', 'webview_destroy(w)')
    $last = -1
    foreach ($step in $order) {
        $idx = $after.IndexOf($step)
        if ($idx -lt 0) { Violation "the teardown step '$step' is absent after webview_run"; continue }
        if ($idx -le $last) { Violation "the teardown step '$step' is out of order" }
        $last = $idx
    }
    $facts['shutdown_order'] = ($order -join '>')
}
# the POSIX helper: its signal handler writes to a pipe and nothing else, and
# its thread performs the SAME dispatch the auto-close thread does
$sigHandler = [regex]::Match($hostCode, '(?s)procedure PWebHostStopSignal\(.*?\nend;')
if (-not $sigHandler.Success) { Violation 'the POSIX stop helper is absent from the host' }
else {
    foreach ($forbidden in 'webview_', 'WriteLn', 'raise', 'Exception', 'FreeAndNil') {
        if ($sigHandler.Value.Contains($forbidden)) {
            Violation "the signal handler does more than write to its pipe: $forbidden"
        }
    }
    if ($sigHandler.Value -notmatch 'FpWrite\(HostStopPipe\[1\]') {
        Violation 'the signal handler does not write to the self-pipe'
    }
}
$dispatches = [regex]::Matches($hostCode, 'webview_dispatch\(webview_t\(handle\), @PWebHostTerminate, nil\)')
if ($dispatches.Count -ne 2) {
    Violation "expected the auto-close thread and the stop thread to share ONE terminate dispatch (found $($dispatches.Count))"
}
$facts['stop_helper_shares_dispatch'] = ($dispatches.Count -eq 2)

# --- 7. the parser's command set is CLOSED -----------------------------------
# CAP-10C2 moved `dev` out of this sweep and CAP-10D0 moved `build`. The rule
# is unchanged - the parser must not accept a command this build cannot
# perform - and only the membership moved, each time in the shard that made
# the command do the whole of what its name says. The sweep is INVERTED
# rather than deleted: its subject is a name no shard will ratify, because
# the claim it has always made is that this parser's command set is closed.
$devBuildHits = 0
foreach ($row in (Get-CodeLines 'tools/pweb/pweb.cli.args.pas')) {
    if ($row.Text -match "token\s*=\s*'(publish|package|deploy|install)'") {
        Violation "the parser accepts an unimplemented command: line $($row.Number)"
        $devBuildHits++
    }
}
$facts['dev_build_absent'] = ($devBuildHits -eq 0)
# and the five that ARE implemented are all still there, so a command that
# quietly disappeared is a violation too
$implemented = 0
foreach ($row in (Get-CodeLines 'tools/pweb/pweb.cli.args.pas')) {
    if ($row.Text -match "token\s*=\s*'(create|doctor|run|dev|build)'") {
        $implemented++
    }
}
$facts['implemented_commands'] = $implemented
if ($implemented -ne 5) {
    Violation ("the parser accepts $implemented of the five commands this " +
        'build implements')
}

# --- verdict ----------------------------------------------------------------
New-Item -ItemType Directory -Force build/cap10c0 | Out-Null
$facts['violations'] = @($violations)
$facts['verdict'] = $(if ($violations.Count -eq 0) { 'PASS' } else { 'FAIL' })
[System.IO.File]::WriteAllText(
    (Join-Path $repoRoot 'build/cap10c0/contracts.json'),
    (($facts | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Write-Host "VIOLATION: $v" }
    throw "CAP-10C0 contract gate FAILED: $($violations.Count) violation(s)"
}
Write-Host ('[CAP-10C0] contracts PASS - bounds stated once, no FPC process ' +
    'unit linked, no name-based kill, runtime ignores the environment, run ' +
    'never builds, shutdown order and dispatch preserved, the command set closed at five')
