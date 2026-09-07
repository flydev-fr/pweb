# CAP-11A: the three hosted flakes are instrumented, and the instrumentation is
# where it says it is.
#
# None of the three is a product defect and all three have cost hosted runs. The
# disposition for each is unchanged - re-run the job, never re-ratify - and what
# this shard adds is that a failure NAMES ITS OWN CAUSE instead of being read out
# of a log by whoever meets it next.
#
# It is a SOURCE gate plus a RUNTIME reader: the source half runs on every leg and
# proves the instrumentation is wired; the runtime half reports whatever rows the
# leg actually produced. A leg that never runs a Windows smoke reports
# `not_applicable` rather than pretending.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

$failures = New-Object System.Collections.Generic.List[string]
function Violation([string]$m) { $script:failures.Add($m); Write-Host "FLAKE VIOLATION: $m" }
function Read-Norm([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { Violation "missing $Path"; return '' }
    return ([System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

# ===========================================================================
# FL1 - the state=0 non-report (B1-10, B2-16, D1-15)
# ===========================================================================
$obs = Read-Norm 'test/cap11a/smokeobserve.ps1'
# `not_applicable` joined the four after the fact that made it necessary was
# measured: the rule ran on every smoke and typed a cause for green runs too,
# because a successful smoke prints its report and the `report:` branch matched
# it. A taxonomy that cannot say "there was no non-report here" makes the
# aggregated row unreadable.
$CAUSES = @('page_never_loaded', 'loaded_script_never_ran', 'ran_missed_window',
            'undetermined', 'not_applicable')
foreach ($c in $CAUSES) {
    if ($obs -notmatch [regex]::Escape("'$c'")) { Violation "the observer never types '$c'" }
}
# the rule must not have a fifth value: a taxonomy that grows silently is a
# taxonomy nobody can compare across targets
$typed = @([regex]::Matches($obs, "\`$cause = '([a-z_]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
foreach ($t in $typed) { if ($CAUSES -notcontains $t) { Violation "the observer types an unratified cause '$t'" } }
Write-Host "[cap11a] FL1 the observer types $($typed.Count) of the $($CAUSES.Count) ratified causes"

# THE WINDOW IS READ, NEVER TYPED. `PWEB_SMOKE_AUTOCLOSE_MS` is a DEADLINE ON
# THE PAGE - hosted run 34127608923 showed it expiring before the report - and
# it used to be the literal 8000 in six places, none of which had measured
# anything. `test/cap11a/smokewindow.ps1` carries the value, the dev-host sweep
# that sized it and the margin; every other site reads it from there.
#
# SWEPT, NOT LISTED, which is the FL3 lesson below applied here: a hand-written
# list of smoke sites goes stale the moment a seventh smoke appears, and this
# gate would cheerfully report six of six.
$WINDOW_OWNER = 'test/cap11a/smokewindow.ps1'
$winSrc = Read-Norm $WINDOW_OWNER
$declaredMs = 0; $measuredMs = 0; $windowMult = 0
if ($winSrc -match '(?m)^\$PWebSmokeAutocloseMs\s*=\s*(\d+)\s*$') { $declaredMs = [int]$Matches[1] }
else { Violation "$WINDOW_OWNER declares no `$PWebSmokeAutocloseMs" }
if ($winSrc -match '(?m)^\$PWebSmokeMeasuredReportMs\s*=\s*(\d+)\s*$') { $measuredMs = [int]$Matches[1] }
else { Violation "$WINDOW_OWNER declares no measured report deadline" }
if ($winSrc -match '(?m)^\$PWebSmokeWindowMultiple\s*=\s*(\d+)\s*$') { $windowMult = [int]$Matches[1] }
else { Violation "$WINDOW_OWNER declares no margin multiple" }
# THE ARITHMETIC IS CHECKED, NOT TRUSTED. The header says the window is a stated
# multiple of a measured deadline; a value edited without the measurement behind
# it moving is exactly the "longer because it flaked" this shard refuses.
if ($declaredMs -ne ($measuredMs * $windowMult)) {
    Violation "the window ${declaredMs} ms is not $windowMult x the measured ${measuredMs} ms"
}
# every example host clamps at 60000, so a window above it is silently ignored
if ($declaredMs -gt 60000) { Violation "the window ${declaredMs} ms exceeds the 60000 ms clamp every host applies" }

# WHICH SITES, and why not simply "every file that sets the variable". A dozen
# gates set `PWEB_SMOKE_AUTOCLOSE_MS` to a deliberate value that IS the thing
# under test - 55000 in the host-argument gates, where the point is that argv
# beats the environment; 45000 and 20000 in the supervision gates, where the
# window has to outlive a supervised stop; 5000 in the CAP-6b4 profile matrix.
# Forcing those onto the smoke window would break the tests that own them.
#
# The set this rule governs is the GUI SMOKE, identified by two properties
# neither of which is a file name:
#
#   1. anything that STARTS the non-report observer is a GUI smoke by
#      construction - that is what the observer watches;
#   2. no CI step body may type the window at all, because a step body is where
#      the six copies of 8000 lived and where a seventh would appear.
$allFiles = @(Get-ChildItem -Path test, .github -Recurse -File -Force -Include *.ps1, *.yml |
    ForEach-Object { $_.FullName.Substring($repoRoot.Length + 1) -replace '\\', '/' } |
    Where-Object { $_ -ne $WINDOW_OWNER } | Sort-Object)
if ($allFiles.Count -lt 100) { Violation "the window sweep enumerated only $($allFiles.Count) files" }

# The machinery is not a smoke, and each exclusion is named with its reason and
# must still exist - an exclusion that silently covers a renamed file is a hole.
# `smokeobserve.ps1` DEFINES the observer; `apply_amendments.ps1` carries CI
# bodies as search-and-replace data, window literal included; this gate quotes
# both names it looks for.
$MACHINERY = @('test/cap11a/smokeobserve.ps1', 'test/cap11a/apply_amendments.ps1',
               'test/cap11a/check_flake_instrumentation.ps1')
foreach ($m in $MACHINERY) { if ($allFiles -notcontains $m) { Violation "the excluded $m is gone" } }
$smokeSites = @($allFiles | Where-Object { $MACHINERY -notcontains $_ } |
    Where-Object { (Read-Norm $_) -match 'Start-PWebSmokeObserver' })
if ($smokeSites.Count -lt 3) {
    Violation "the sweep found $($smokeSites.Count) instrumented GUI smoke(s), fewer than the three that exist"
}
foreach ($s in $smokeSites) {
    $t = Read-Norm $s
    if ($t -match "PWEB_SMOKE_AUTOCLOSE_MS\s*=\s*'?\d") { Violation "$s types the auto-close window instead of reading it" }
    if ($t -notmatch 'smokewindow\.ps1') { Violation "$s starts the observer without loading $WINDOW_OWNER" }
    if ($t -notmatch 'Set-PWebSmokeWindow') { Violation "$s does not set the window through Set-PWebSmokeWindow" }
    # the observation must record the window that was actually in force
    if ($t -match '-AutocloseMs\s+\d') { Violation "$s records a typed window in its observation" }
}

$ciSites = @($allFiles | Where-Object { $_ -like '.github/*' })
$ciTyped = @($ciSites | Where-Object { (Read-Norm $_) -match "PWEB_SMOKE_AUTOCLOSE_MS\s*=\s*'?\d" })
foreach ($c in $ciTyped) { Violation "$c types the auto-close window into a CI step body" }
$ciReaders = @($ciSites | Where-Object { (Read-Norm $_) -match 'Set-PWebSmokeWindow' })
if ($ciReaders.Count -lt 4) {
    Violation "only $($ciReaders.Count) CI step bodies read the window; four GUI smokes run in the matrix"
}
Write-Host ("[cap11a] FL1 the ${declaredMs} ms window ($windowMult x the measured ${measuredMs} ms) " +
    "is read by $($smokeSites.Count) instrumented smoke(s) and $($ciReaders.Count) CI step body(ies)")

# THREE DRIVERS, not two. The CAP-4 dual-mode smoke joined the list on evidence
# rather than on the brief's enumeration: it produced the non-report during this
# shard's own twin run.
foreach ($d in @('test/cap6/run_cap6_smoke.ps1', 'test/cap5/run_cap5_smokes.ps1',
                 '.github/actions/cap-4-dual-mode-runtime-best-effort-local-gate-authoritative/action.yml')) {
    $t = Read-Norm $d
    if ($t -notmatch 'smokeobserve\.ps1') { Violation "$d does not load the observer" }
    if ($t -notmatch 'Start-PWebSmokeObserver') { Violation "$d never starts the observer" }
    if ($t -notmatch 'Stop-PWebSmokeObserver') { Violation "$d never types a cause" }
    # THE OBSERVER MUST NOT BE ABLE TO FAIL THE GATE. Its call site is wrapped,
    # and an instrumentation that could turn a green smoke red would be worse
    # than the flake it explains.
    if ($t -notmatch '(?s)try \{[^}]*Stop-PWebSmokeObserver') {
        Violation "$d calls the observer outside a try/catch"
    }
}

$nonreportRow = 'not_applicable'
$smokeObsFiles = @(@('build/cap6/smoke-observations.txt',
                     'build/cap5/smoke-observations-react.txt',
                     'build/cap5/smoke-observations-pas2js.txt',
                     'build/cap4/smoke-observations-folder.txt',
                     'build/cap4/smoke-observations-zip.txt') |
    Where-Object { Test-Path -LiteralPath $_ })
if ($smokeObsFiles.Count -gt 0) {
    $causes = @()
    foreach ($f in $smokeObsFiles) {
        $first = (Get-Content -LiteralPath $f -TotalCount 1)
        if ($first -match '^cause=([a-z_]+)$') { $causes += $Matches[1] }
        else { Violation "$f does not begin with a typed cause row" }
    }
    # PIPE, not comma: the POSIX evidence emitter reads this record with the
    # repository's one-line sed idiom, whose value class stops at a comma. A
    # two-smoke leg would otherwise have its second cause silently truncated
    # away on three of the four targets.
    $nonreportRow = ($causes -join '|')
    Write-Host "[cap11a] FL1 observed causes: $nonreportRow"
} else {
    Write-Host '[cap11a] FL1 no smoke observation files on this leg (not_applicable)'
}

# ===========================================================================
# FL2 - the CAP-6b4 U3 uninstall residue (D1-16)
# ===========================================================================
$pm = Read-Norm 'test/cap6b4/run_profile_matrix.ps1'
if ($pm -notmatch 'wv2procdrain\.ps1') { Violation 'the CAP-6b4 matrix does not load the CAP-6b3 drain' }
if ($pm -notmatch 'Invoke-PWebProcessDrain') { Violation 'the CAP-6b4 matrix never runs the path-scoped drain' }
# THE ORDER, which is the whole of what D1-16 asked for: the drain must run and
# REPORT before the uninstaller and therefore before the directory is measured.
$iDrainCall = $pm.IndexOf('Invoke-DrainBeforeUninstall $Row')
$iUnins = $pm.IndexOf('$u = Invoke-Bounded $unins')
$iMeasure = $pm.IndexOf('the install directory itself survived the uninstall')
$u3DrainBeforeMeasure = 'false'
if ($iDrainCall -lt 0) { Violation 'the matrix never calls the drain from the uninstall path' }
elseif ($iUnins -lt 0 -or $iMeasure -lt 0) { Violation 'the uninstall or the directory measure moved; the order cannot be checked' }
elseif (-not (($iDrainCall -lt $iUnins) -and ($iUnins -lt $iMeasure))) {
    Violation "the drain does not precede the uninstall and the measure (drain@$iDrainCall unins@$iUnins measure@$iMeasure)"
} else {
    $u3DrainBeforeMeasure = 'true'
    Write-Host '[cap11a] FL2 the drain is reported before the uninstall and before the directory measure'
}
# THE CAP-6b3 RULE IS UNCHANGED: scoped by path, never by image name.
foreach ($banned in 'taskkill /IM', 'Stop-Process -Name') {
    if ($pm -match [regex]::Escape($banned)) { Violation "the CAP-6b4 matrix uses a name-scoped kill: $banned" }
}
$drainSrc = Read-Norm 'test/cap6b3/wv2procdrain.ps1'
if ($drainSrc -notmatch 'Test-PWebPathUnderRoot') { Violation 'the drain lost its path-scoping predicate' }

$u3Rows = 'not_applicable'
if (Test-Path -LiteralPath 'build/cap6b4/u3-drain.txt') {
    $rows = @(Get-Content -LiteralPath 'build/cap6b4/u3-drain.txt')
    $u3Rows = "$($rows.Count)"
    $summary = @($rows | Where-Object { $_ -match 'sweeps=' })
    if ($summary.Count -eq 0) { Violation 'the drain report carries no sweeps/graceful/terminated row' }
    Write-Host "[cap11a] FL2 drain report: $($rows.Count) row(s)"
}

# ===========================================================================
# FL3 - the pinned-installer fetch stalls (C3-15)
# ===========================================================================
# THE SET IS SWEPT, NOT LISTED, and the sweep is over NAMES rather than over
# transports - because the whole point of the refactor is that a converted
# fetcher no longer contains a transport to find. A hand-written list is a list
# that goes stale: `tools/get-mormot.ps1` sat outside one for this entire shard
# while the gate cheerfully reported five of five converted.
#
# THE RULE: every `tools/get-*.ps1` either routes an HTTP transfer through the
# bounded helper, or performs no HTTP transfer at all. `get-webview.ps1` is the
# second kind - it fetches by git at a pinned SHA, which the floating-ref guard
# covers - and it is refused the moment it grows one.
$HTTP = 'Invoke-WebRequest|Start-BitsTransfer|System\.Net\.WebClient|curl(\.exe)? -'
$FETCHERS = @()
$plain = @()
foreach ($f in @(Get-ChildItem -Path tools -Filter 'get-*.ps1' -File | Sort-Object Name)) {
    $rel = 'tools/' + $f.Name
    $t = Read-Norm $rel
    # comment lines never count: several scripts explain a transport they no
    # longer perform
    $code = (($t -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $usesHelper = ($code -match 'Invoke-PWebFetch')
    $usesHttp = ($code -match $HTTP)
    if ($usesHelper) {
        $FETCHERS += $rel
        if ($code -notmatch 'pwebfetch\.ps1') { Violation "$rel calls the helper without loading it" }
        if ($code -match "Sha256 '[0-9a-f]{64}'") { Violation "$rel inlines a digest instead of reading the lock" }
    } elseif ($usesHttp) {
        Violation "$rel performs an HTTP transfer outside the bounded helper"
    } else {
        $plain += $rel
    }
}
if ($FETCHERS.Count -ne 6) {
    Violation ("the sweep found $($FETCHERS.Count) helper-routed fetchers under tools/, not the six ratified: " +
        ($FETCHERS -join ', '))
}
Write-Host "[cap11a] FL3 $($FETCHERS.Count) helper-routed fetcher(s); $($plain.Count) with no HTTP transfer [$($plain -join ', ')]"
$helper = Read-Norm 'tools/pwebfetch.ps1'
if ($helper -notmatch '\$PWEB_FETCH_ATTEMPTS = 3') { Violation 'the ratified attempt count moved' }
if ($helper -notmatch '\$PWEB_FETCH_BOUND_SECONDS = 180') { Violation 'the ratified per-attempt bound moved' }
# A DIGEST MISMATCH MAY NEVER BE RETRIED - the one property that keeps a retry
# from turning a pin into a suggestion. `check_pwebfetch.ps1` proves it with a
# seeded case; this proves the refusal is still written down.
if ($helper -notmatch "ratify a new pin deliberately \(never retried\)") {
    Violation 'the helper no longer refuses a digest mismatch outright'
}
Write-Host "[cap11a] FL3 $($FETCHERS.Count) fetchers route through the bounded helper (3 x 180s)"

$fetchRows = 'not_applicable'
if (Test-Path -LiteralPath 'build/fetch/rows.txt') {
    $rows = @(Get-Content -LiteralPath 'build/fetch/rows.txt')
    $bad = @($rows | Where-Object { $_ -notmatch 'attempt=\d+/3 bound_s=180 ' })
    foreach ($b in $bad) { Violation "a fetch row is outside the ratified bound: $b" }
    $fetchRows = "$($rows.Count)"
    Write-Host "[cap11a] FL3 $($rows.Count) fetch attempt row(s), all within the bound"
}

# ===========================================================================
New-Item -ItemType Directory -Force build/cap11a | Out-Null
$out = [ordered]@{
    schema                    = 1
    flake_nonreport_cause_row = if ($nonreportRow -eq 'not_applicable') { 'not_applicable' } else { 'present' }
    flake_nonreport_causes    = $nonreportRow
    u3_drain_before_measure   = $u3DrainBeforeMeasure
    u3_drain_rows             = $u3Rows
    fetch_retry_rows          = $fetchRows
    fetch_retry_max_attempts  = 3
    fetch_retry_bound_s       = 180
    violations                = $failures.Count
}
$json = ($out | ConvertTo-Json -Depth 4)
[System.IO.File]::WriteAllText((Join-Path $repoRoot 'build/cap11a/flakes.json'),
    ($json -replace "`r`n", "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "CAP-11A FLAKE INSTRUMENTATION FAILED ($($failures.Count) violation(s))"
    exit 1
}
Write-Host "CAP11A_FLAKES_PASS nonreport=$nonreportRow u3_drain_before_measure=$u3DrainBeforeMeasure fetch_rows=$fetchRows"
exit 0
