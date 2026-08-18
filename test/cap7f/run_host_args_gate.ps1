# CAP-7F: the CAP-7M2 host arguments EXECUTED on Windows (closes
# deferred-work D1 on this platform). The release host gained
# --pweb-verdict= / --pweb-autoclose-ms= on ALL platforms in CAP-7M2, but
# off macOS the paths were only ever compiled: the CAP-6 gates launch
# releaseapp.exe argument-free. This gate runs the argumented matrix on the
# REAL assembled release triple (build/cap6/release, exe + app.pwb + dll),
# from an unrelated CWD, exactly as the macOS release gate runs it on the
# .app products:
#
#   PASS leg   --pweb-verdict=<file> --pweb-autoclose-ms=4000 with the
#              environment deliberately carrying PWEB_SMOKE_AUTOCLOSE_MS=55000:
#              the canonical PASS line must land in the verdict file AND the
#              wall clock must prove argv won over the environment. The bound
#              is TWO-SIDED: < 45 s (a run obeying the env would take >= 55 s)
#              AND >= 3 s (a run that exited before its own 4 s autoclose
#              never ran the autoclose it claims argv selected).
#   refusals   unknown argument, malformed --pweb-autoclose-ms=x, duplicated
#              --pweb-autoclose-ms (with two DIFFERENT values, so last-one-wins
#              could never masquerade as a refusal), duplicated --pweb-verdict=
#              (whose FAIL verdict must land in the LAST path - pass-1 capture
#              semantics per releaseapp.pas - and never in the first) - each
#              refused with a nonzero exit and its typed message, each still
#              writing a FAIL verdict file. Refusal launches are BOUNDED
#              (30 s + kill) with a small env autoclose exported, so a
#              regressed parser that silently ACCEPTED the bogus argument
#              fails fast here instead of idling out the step budget.
#
# CONDITIONAL HOSTED POLICY, mirrored from test/cap6/run_cap6_smoke.ps1: a
# genuine failure gates (exit 1); only an absent WebView2/desktop session
# records SKIP - and only for the PASS leg, because every refusal fires in
# ParseArguments BEFORE the runtime pre-check and needs no WebView at all.
# The refusal legs therefore gate unconditionally. A nil-create marker with
# exit 0 is an inconsistent state and FAILS (a refusal that does not refuse
# is a defect), exactly as the smoke script treats its own marker. The SKIP
# is recorded honestly in build/cap7f/host-args.json, where the CAP-7F
# aggregator REFUSES it - a runner regression turns the aggregate red,
# never green.
#
# The PASS marker is greped from the VERDICT_PASS constant in
# examples/08-release/releaseapp.pas - single-source, same discipline as
# test/cap7m/run_cap7m_release.sh - so this gate can never drift into
# grepping a line nobody emits.
#
# Writes: build/cap7f/host-args.json (+ per-leg logs under build/cap7f/).
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

foreach ($pre in 'build/cap6/release/releaseapp.exe',
                 'build/cap6/release/app.pwb',
                 'build/cap6/release/webview.dll') {
    if (-not (Test-Path $pre)) {
        throw ("missing precondition: $pre -- run " +
            'test/cap6/run_cap6_gates.ps1 first (it assembles the release dir)')
    }
}

New-Item -ItemType Directory -Force build/cap7f | Out-Null
$work = (Resolve-Path build/cap7f).Path
$exe = (Resolve-Path build/cap6/release/releaseapp.exe).Path

# --- the canonical verdict line, greped strictly from the one source -------
$verdictConst = @(Select-String -Path examples/08-release/releaseapp.pas `
    -Pattern "^  VERDICT_PASS = '([^']+)';$" -CaseSensitive)
if ($verdictConst.Count -ne 1) {
    throw ("expected exactly one VERDICT_PASS constant in releaseapp.pas, " +
        "found $($verdictConst.Count)")
}
$passLine = 'releaseapp' + $verdictConst[0].Matches[0].Groups[1].Value
Write-Host "[CAP-7F] canonical verdict line: $passLine"

function Invoke-ReleaseArgs([string[]]$AppArgs) {
    # unrelated CWD, exactly like the CAP-6 smoke: the layout must never
    # depend on where the caller stood
    Push-Location ([System.IO.Path]::GetTempPath())
    try {
        $out = & $exe @AppArgs 2>&1 | Out-String
        return @{ Out = $out; Code = $LASTEXITCODE }
    } finally { Pop-Location }
}

# Bounded sibling for the refusal legs: a refusal is expected in
# milliseconds, so anything that is still alive after the bound has
# ACCEPTED an argument it must refuse - killed and failed loudly.
function Invoke-ReleaseArgsBounded([string[]]$AppArgs, [int]$TimeoutSec) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    foreach ($a in $AppArgs) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = [System.IO.Path]::GetTempPath()
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill($true) } catch { }
        throw ("bounded refusal launch exceeded ${TimeoutSec}s -- the host " +
            'accepted (or hung on) an argument it must refuse')
    }
    $p.WaitForExit()  # drain the async readers after the hard exit
    return @{ Out = ($outTask.Result + $errTask.Result); Code = $p.ExitCode }
}

function Assert-FailVerdict([string]$Leg, [string]$File) {
    if (-not (Test-Path $File)) {
        throw "${Leg}: the refused launch left no FAIL verdict file"
    }
    $line = (Get-Content $File -Raw)
    if ($line -notmatch [regex]::Escape('releaseapp: FAIL')) {
        throw "${Leg}: the refusal verdict does not carry the FAIL line: $line"
    }
}

# --- PASS leg: verdict file + argv beats the 55 s environment --------------
$passVerdict = Join-Path $work 'verdict-pass.txt'
Remove-Item -Force -ErrorAction SilentlyContinue $passVerdict
$env:PWEB_SMOKE_AUTOCLOSE_MS = '55000'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $r = Invoke-ReleaseArgs @("--pweb-verdict=$passVerdict",
                              '--pweb-autoclose-ms=4000')
} finally {
    $sw.Stop()
    Remove-Item Env:\PWEB_SMOKE_AUTOCLOSE_MS -ErrorAction SilentlyContinue
}
$elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)
$r.Out | Out-File -Encoding utf8 (Join-Path $work 'host-args-pass.log')
Write-Host $r.Out

$passLeg = ''
if (($r.Code -eq 0) -and ($r.Out -match [regex]::Escape($passLine))) {
    if (-not (Test-Path $passVerdict)) {
        throw 'PASS leg: the run left no verdict file'
    }
    $vline = (Get-Content $passVerdict -Raw).TrimEnd("`r", "`n")
    if ($vline -cne $passLine) {
        throw "PASS leg: verdict file holds '$vline', expected '$passLine'"
    }
    # the same three page-report facts the Linux gate asserts, at the gate:
    # a live secure pweb://app origin and the anchored RPC 42 (anchored so
    # "value":420 can never satisfy it)
    if ($r.Out -notmatch '"secure":true') {
        throw 'PASS leg: the page never reported "secure":true'
    }
    if ($r.Out -notmatch '"value":42([^0-9]|$)') {
        throw 'PASS leg: the page never reported the anchored "value":42'
    }
    if ($r.Out -notmatch [regex]::Escape('pweb://app')) {
        throw 'PASS leg: the run never named the pweb://app origin'
    }
    # CAP-8A runtime deny enforcement: the page probes an UNMAPPED method
    # (Denied.Probe) and reports whether the production policy answered
    # typed forbidden/403. An allow-all regression would let the probe
    # reach the bridge and 404 ("denied":false) - and go red RIGHT HERE.
    if ($r.Out -notmatch '"denied":true') {
        throw 'PASS leg: the page never reported "denied":true -- the production policy did not forbid the unmapped probe'
    }
    if ($elapsed -ge 45) {
        throw ("PASS leg: the run took ${elapsed}s -- the argv autoclose " +
            '(4000ms) did not win over PWEB_SMOKE_AUTOCLOSE_MS=55000')
    }
    if ($elapsed -lt 3) {
        throw ("PASS leg: the run took only ${elapsed}s -- it exited before " +
            'its own 4000ms autoclose, so this run proves nothing about argv precedence')
    }
    $passLeg = 'PASS'
    Write-Host ("[CAP-7F] PASS leg: canonical verdict in the file, " +
        "argv won by wall clock (3s <= ${elapsed}s < 45s)")
}
elseif (($r.Out -match 'WEBVIEW2 RUNTIME UNUSABLE') -and ($r.Code -ne 0)) {
    # same conditional hosted policy as run_cap6_smoke.ps1 - and even the
    # SKIP shape must have honoured the verdict contract: the runtime
    # pre-check raises AFTER ParseArguments, so a FAIL verdict must exist
    Assert-FailVerdict 'PASS-leg-SKIP' $passVerdict
    $passLeg = 'SKIP'
    Write-Host "[CAP-7F] PASS leg: SKIP - runtime unusable on this runner (exit $($r.Code)), FAIL verdict present"
}
elseif (($r.Out -match 'webview_create \(returned nil') -and ($r.Code -ne 0)) {
    # the marker with exit 0 is an inconsistent state and falls through to
    # FAIL below - a refusal that does not refuse is a defect (the same
    # rule run_cap6_smoke.ps1 states for its own SKIP shapes)
    Assert-FailVerdict 'PASS-leg-SKIP' $passVerdict
    $passLeg = 'SKIP'
    Write-Host "[CAP-7F] PASS leg: SKIP - no usable WebView2/desktop session (exit $($r.Code)), FAIL verdict present"
}
else {
    throw "PASS leg FAILED: exit $($r.Code) or missing verdict line (see log)"
}
$argvBeatsEnv = $passLeg  # proven by the same bounded run, skipped with it

# --- refusal legs: unconditional (they fire before any runtime check) ------
# A small env autoclose is exported for the whole block: if a regressed
# parser ACCEPTED one of these command lines, the run auto-closes in 8 s
# and fails on its exit code/marker instead of hanging into the bound.
$vfUnknown = Join-Path $work 'verdict-refusal_unknown.txt'
$vfMalformed = Join-Path $work 'verdict-refusal_malformed.txt'
$vfDuplicate = Join-Path $work 'verdict-refusal_duplicate.txt'
$vfDupVerdictFirst = Join-Path $work 'verdict-refusal_dup_verdict_first.txt'
$vfDupVerdictLast = Join-Path $work 'verdict-refusal_dup_verdict_last.txt'
$refusals = @(
    @{ Name = 'refusal_unknown'
       Args = @("--pweb-verdict=$vfUnknown", '--pweb-bogus-argument')
       Marker = 'usage:'
       Verdict = $vfUnknown },
    @{ Name = 'refusal_malformed'
       Args = @("--pweb-verdict=$vfMalformed", '--pweb-autoclose-ms=x')
       Marker = 'requires a non-negative integer'
       Verdict = $vfMalformed },
    @{ Name = 'refusal_duplicate'
       # two DIFFERENT values: a last-one-wins parser would accept this
       # command line and run 55 s, which the bound + exit-code turn into
       # a loud failure rather than a silent acceptance
       Args = @("--pweb-verdict=$vfDuplicate", '--pweb-autoclose-ms=4000',
                '--pweb-autoclose-ms=55000')
       Marker = 'duplicate argument refused'
       Verdict = $vfDuplicate },
    @{ Name = 'refusal_duplicate_verdict'
       # pass-1 captures the LAST path, pass-2 refuses the duplication: the
       # FAIL verdict must land in the last path and never in the first
       Args = @("--pweb-verdict=$vfDupVerdictFirst",
                "--pweb-verdict=$vfDupVerdictLast")
       Marker = 'duplicate argument refused'
       Verdict = $vfDupVerdictLast
       AbsentVerdict = $vfDupVerdictFirst }
)
$refusalResults = @{}
$env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'
try {
    foreach ($leg in $refusals) {
        foreach ($f in @($leg.Verdict; $leg['AbsentVerdict'])) {
            if ($f) { Remove-Item -Force -ErrorAction SilentlyContinue $f }
        }
        $r = Invoke-ReleaseArgsBounded $leg.Args 30
        $r.Out | Out-File -Encoding utf8 (Join-Path $work "host-args-$($leg.Name).log")
        if ($r.Code -eq 0) {
            throw "$($leg.Name): releaseapp exited zero where a refusal was required"
        }
        if ($r.Out -notmatch [regex]::Escape($leg.Marker)) {
            Write-Host $r.Out
            throw "$($leg.Name): missing the typed marker [$($leg.Marker)]"
        }
        # fail-closed means BEFORE any WebView: a refusal output carrying the
        # runtime verdict would mean content executed after the parse said no
        if ($r.Out -match [regex]::Escape($passLine)) {
            throw "$($leg.Name): the refusal output carries a runtime verdict"
        }
        Assert-FailVerdict $leg.Name $leg.Verdict
        if ($leg['AbsentVerdict'] -and (Test-Path $leg.AbsentVerdict)) {
            throw ("$($leg.Name): a verdict landed in the FIRST duplicated " +
                'path - pass-1 last-capture semantics were not honoured')
        }
        $refusalResults[$leg.Name] = 'PASS'
        Write-Host "[CAP-7F] $($leg.Name): refused with exit $($r.Code), marker + FAIL verdict present"
    }
} finally {
    Remove-Item Env:\PWEB_SMOKE_AUTOCLOSE_MS -ErrorAction SilentlyContinue
}

# --- the record the emitter and the aggregator read ------------------------
$overall = if ($passLeg -eq 'PASS') { 'PASS' } else { 'SKIP' }
$record = [ordered]@{
    schema                    = 1
    os                        = 'windows'
    pass_leg                  = $passLeg
    argv_beats_env            = $argvBeatsEnv
    elapsed_s                 = $elapsed
    refusal_unknown           = $refusalResults['refusal_unknown']
    refusal_malformed         = $refusalResults['refusal_malformed']
    refusal_duplicate         = $refusalResults['refusal_duplicate']
    refusal_duplicate_verdict = $refusalResults['refusal_duplicate_verdict']
    overall                   = $overall
    verdict_line              = $passLine
}
$json = $record | ConvertTo-Json
[System.IO.File]::WriteAllText((Join-Path $work 'host-args.json'),
    $json + "`n", [System.Text.UTF8Encoding]::new($false))

if ($env:GITHUB_STEP_SUMMARY) {
    "### CAP-7F Windows host-argument gate`noverall: $overall (pass leg $passLeg, elapsed ${elapsed}s, 4/4 refusals PASS with FAIL verdicts)" |
        Out-File -Append $env:GITHUB_STEP_SUMMARY
}
Write-Host "[CAP-7F] run_host_args_gate: $overall (refusal matrix PASS; PASS leg $passLeg)"
