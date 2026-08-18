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
#              wall clock must prove argv won over the environment (a run
#              obeying the env would take >= 55 s; the bound here is 45 s).
#   refusals   unknown argument, malformed --pweb-autoclose-ms=x, duplicated
#              option - each refused with a nonzero exit and its typed
#              message, each still writing a FAIL verdict file (the whole
#              point of parse-pass-1: a refused command line must leave the
#              one evidence channel a stdout-less launch has).
#
# CONDITIONAL HOSTED POLICY, mirrored from test/cap6/run_cap6_smoke.ps1: a
# genuine failure gates (exit 1); only an absent WebView2/desktop session
# records SKIP - and only for the PASS leg, because every refusal fires in
# ParseArguments BEFORE the runtime pre-check and needs no WebView at all.
# The refusal legs therefore gate unconditionally. The SKIP is recorded
# honestly in build/cap7f/host-args.json, where the CAP-7F aggregator
# REFUSES it - a runner regression turns the aggregate red, never green.
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
    if ($elapsed -ge 45) {
        throw ("PASS leg: the run took ${elapsed}s -- the argv autoclose " +
            '(4000ms) did not win over PWEB_SMOKE_AUTOCLOSE_MS=55000')
    }
    $passLeg = 'PASS'
    Write-Host ("[CAP-7F] PASS leg: canonical verdict in the file, " +
        "argv won by wall clock (${elapsed}s < 45s)")
}
elseif (($r.Out -match 'WEBVIEW2 RUNTIME UNUSABLE') -and ($r.Code -ne 0)) {
    # same conditional hosted policy as run_cap6_smoke.ps1 - and even the
    # SKIP shape must have honoured the verdict contract: the runtime
    # pre-check raises AFTER ParseArguments, so a FAIL verdict must exist
    Assert-FailVerdict 'PASS-leg-SKIP' $passVerdict
    $passLeg = 'SKIP'
    Write-Host "[CAP-7F] PASS leg: SKIP - runtime unusable on this runner (exit $($r.Code)), FAIL verdict present"
}
elseif ($r.Out -match 'webview_create \(returned nil') {
    Assert-FailVerdict 'PASS-leg-SKIP' $passVerdict
    $passLeg = 'SKIP'
    Write-Host "[CAP-7F] PASS leg: SKIP - no usable WebView2/desktop session (exit $($r.Code)), FAIL verdict present"
}
else {
    throw "PASS leg FAILED: exit $($r.Code) or missing verdict line (see log)"
}
$argvBeatsEnv = $passLeg  # proven by the same bounded run, skipped with it

# --- refusal legs: unconditional (they fire before any runtime check) ------
$refusals = @(
    @{ Name = 'refusal_unknown'
       Args = @('--pweb-bogus-argument')
       Marker = 'usage:' },
    @{ Name = 'refusal_malformed'
       Args = @('--pweb-autoclose-ms=x')
       Marker = 'requires a non-negative integer' },
    @{ Name = 'refusal_duplicate'
       Args = @('--pweb-autoclose-ms=4000', '--pweb-autoclose-ms=4000')
       Marker = 'duplicate argument refused' }
)
$refusalResults = @{}
foreach ($leg in $refusals) {
    $vf = Join-Path $work "verdict-$($leg.Name).txt"
    Remove-Item -Force -ErrorAction SilentlyContinue $vf
    $r = Invoke-ReleaseArgs (@("--pweb-verdict=$vf") + $leg.Args)
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
    Assert-FailVerdict $leg.Name $vf
    $refusalResults[$leg.Name] = 'PASS'
    Write-Host "[CAP-7F] $($leg.Name): refused with exit $($r.Code), marker + FAIL verdict present"
}

# --- the record the emitter and the aggregator read ------------------------
$overall = if ($passLeg -eq 'PASS') { 'PASS' } else { 'SKIP' }
$record = [ordered]@{
    schema            = 1
    os                = 'windows'
    pass_leg          = $passLeg
    argv_beats_env    = $argvBeatsEnv
    elapsed_s         = $elapsed
    refusal_unknown   = $refusalResults['refusal_unknown']
    refusal_malformed = $refusalResults['refusal_malformed']
    refusal_duplicate = $refusalResults['refusal_duplicate']
    overall           = $overall
    verdict_line      = $passLine
}
$json = $record | ConvertTo-Json
[System.IO.File]::WriteAllText((Join-Path $work 'host-args.json'),
    $json + "`n", [System.Text.UTF8Encoding]::new($false))

if ($env:GITHUB_STEP_SUMMARY) {
    "### CAP-7F Windows host-argument gate`noverall: $overall (pass leg $passLeg, elapsed ${elapsed}s, 3/3 refusals PASS with FAIL verdicts)" |
        Out-File -Append $env:GITHUB_STEP_SUMMARY
}
Write-Host "[CAP-7F] run_host_args_gate: $overall (refusal matrix PASS; PASS leg $passLeg)"
