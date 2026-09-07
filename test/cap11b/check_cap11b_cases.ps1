# CAP-11B: the seeded verdicts. Six typed outcomes, offline, on every leg.
#
# The watcher's real run answers one question about upstream and, upstream
# being where it is on any given week, will answer `unchanged` almost always.
# That proves the machinery starts; it proves nothing about the five other
# verdicts. These cases drive the SAME driver through a named seam with a
# seeded input and require each verdict to come out typed, with the evidence
# the contract says it carries.
#
#   W2  head == pinned            -> unchanged, diff empty
#   W3  one added prototype       -> compatible_additive, the diff names it
#   W4  one changed signature     -> abi_break, signature_pin fails to compile
#   W5a the patch context moved   -> patch_drift (rejected), with the hunk
#   W5b the patch position moved  -> patch_drift (offset), with the offset
#   W6  the library build fails   -> build_failed, with the log tail
#   W7  the fetch is refused      -> inconclusive, with the cause
#
# NOTHING HERE TOUCHES THE NETWORK. Every fixture is built from the PINNED
# checkout the leg already fetched, by an EXACT-MATCH text edit - a seed that
# silently matched nothing would produce a green case that tested nothing, so
# a missing anchor throws.
#
# W4 IS A REAL COMPILE. FPC is on every leg, the projection of the seeded
# header really is fed to test/core/signature_pin.pas, and the case passes only
# because that compile really fails. Nothing is simulated except the network,
# the library build, and the passage of time.
#
# Emits build/cap11b/cases.json and exits nonzero on any violation.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
function Violation([string]$Text) { $violations.Add($Text); Write-Host "VIOLATION: $Text" }
function Get-FileSha([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

$pinned = Join-Path $repoRoot 'deps/webview'
if (-not (Test-Path -LiteralPath (Join-Path $pinned 'core/include/webview/api.h'))) {
    throw 'deps/webview is missing -- the pinned checkout is the source of every fixture here'
}
foreach ($tool in 'fpc', 'git') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "required tool not found: $tool" }
}

$casesRoot = Join-Path $repoRoot 'build/cap11b/cases'
if (Test-Path -LiteralPath $casesRoot) { Remove-Item -Recurse -Force -LiteralPath $casesRoot }
New-Item -ItemType Directory -Force $casesRoot | Out-Null

$locksBefore = @{
    webview = Get-FileSha (Join-Path $repoRoot 'webview.lock')
    mormot  = Get-FileSha (Join-Path $repoRoot 'mormot.lock')
}

# --- the precondition, named rather than skipped -----------------------------
# Four of the cases below assert a COMPILE outcome, so a host whose FPC cannot
# produce a binary for this platform at all would fail them for a reason that
# has nothing to do with the seeds. That is worth ONE clear sentence rather
# than eight confusing case failures - and it is a refusal, never a skip: on
# every CI leg the pinned FPC compiles this, so the gate stays a gate.
$fpcTarget = (& fpc -iTP 2>&1 | Out-String).Trim()
$fpcOs = (& fpc -iTO 2>&1 | Out-String).Trim()
# THE TARGET THIS LEG IS. The platform leg sets PWEB_CI_TARGET; off CI it is
# derived from the host, so a developer gets the same behaviour without having
# to know the variable exists.
$legTarget = if ($env:PWEB_CI_TARGET) { $env:PWEB_CI_TARGET }
    elseif ($IsWindows) { 'windows' }
    elseif ($IsLinux) { 'linux' }
    elseif ($fpcTarget -ceq 'aarch64') { 'macos-arm64' }
    else { 'macos-x64' }
# EVERY HOST, not only Windows. The projected binding declares LIB_WEBVIEW for
# WIN64, DARWIN and LINUX on x86_64/aarch64 only, so any other FPC target makes
# every compile-based case report `inconclusive` ABOUT THE HOST rather than
# about its seed. One named sentence beats eight confusing case failures - and
# it is a REFUSAL, never a skip, so the gate stays a gate on every CI leg.
$wantCpu = if ($legTarget -eq 'macos-arm64') { 'aarch64' } else { 'x86_64' }
if ($fpcTarget -cne $wantCpu) {
    Write-Host "[cap11b] REFUSED: this host's FPC targets $fpcTarget-$fpcOs; target '$legTarget' needs $wantCpu."
    Write-Host '[cap11b] The projected binding declares LIB_WEBVIEW only for WIN64, DARWIN and LINUX, so a'
    Write-Host '[cap11b] compiler for another CPU stops at the unsupported-platform message and every'
    Write-Host '[cap11b] compile-based case below would report `inconclusive` about the HOST, not the seed.'
    Write-Host '[cap11b] Each CI leg installs the pinned FPC for its own target and does run these.'
    exit 1
}

# --- fixture construction -----------------------------------------------------
# The public headers only, unless a case needs the two files the CAP-4W patch
# touches. Copying the whole checkout would be 60 MB per case for no gain.
$PATCH_TARGETS = @(
    'core/include/webview/detail/backends/win32_edge.hh',
    'core/include/webview/detail/platform/windows/webview2/loader.hh'
)
# EVERY FIXTURE FILE COMES FROM THE PINNED COMMIT'S BLOB, NOT FROM THE WORKING
# TREE, and that is the second time this file has had to learn the lesson.
#
#   the first: Git for Windows checks `deps/webview` out with CRLF
#   (core.autocrlf=true) while the CAP-4W patch is LF, so a fixture copied from
#   disk made `git apply` fail on CONTEXT rather than on the seed.
#
#   the second, found by the CONTROL case on hosted run 34113334940: on the
#   WINDOWS leg `deps/webview` is ALREADY PATCHED by the time this gate runs -
#   `tools/build-webview-dll.ps1` applies the CAP-4W patch and leaves it applied
#   - so a fixture copied from disk carried a patched `win32_edge.hh` and the
#   pinned patch was rejected by its own output.
#
# `git show <pin>:<path>` answers both at once: it is the blob, so it is LF and
# it is the pin, whatever the working tree happens to be. The fixture repository
# is still created with core.autocrlf=false so those bytes survive on Windows.
$PINNED_COMMIT_FOR_FIXTURES = (git -C $pinned rev-parse HEAD 2>$null)
if ([string]::IsNullOrWhiteSpace($PINNED_COMMIT_FOR_FIXTURES)) {
    throw 'deps/webview has no readable HEAD; the fixtures have no pinned source'
}
$PINNED_COMMIT_FOR_FIXTURES = "$PINNED_COMMIT_FOR_FIXTURES".Trim()
function Copy-FromPin([string]$Rel, [string]$To) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.WorkingDirectory = $pinned
    foreach ($a in @('show', "$PINNED_COMMIT_FOR_FIXTURES`:$Rel")) { [void]$psi.ArgumentList.Add($a) }
    $p = [Diagnostics.Process]::Start($psi)
    $soTask = $p.StandardOutput.ReadToEndAsync()
    $seTask = $p.StandardError.ReadToEndAsync()
    [void][Threading.Tasks.Task]::WaitAll(@($soTask, $seTask))
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "git show of the pinned $Rel failed: $($seTask.Result.Trim())" }
    [IO.File]::WriteAllText($To, ($soTask.Result -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}
function Get-PinnedHeaderNames {
    $out = @(git -C $pinned ls-tree --name-only "$PINNED_COMMIT_FOR_FIXTURES" 'core/include/webview/' 2>$null)
    return @($out | Where-Object { $_ -match '\.h$' })
}
function New-Fixture([string]$Name, [switch]$WithPatchTargets, [switch]$AsGitRepo) {
    $dir = Join-Path $casesRoot $Name
    $inc = Join-Path $dir 'core/include/webview'
    New-Item -ItemType Directory -Force $inc | Out-Null
    $headerRels = Get-PinnedHeaderNames
    if ($headerRels.Count -lt 5) {
        throw "the pinned tree lists $($headerRels.Count) public headers; the fixture would be a fixture of nothing"
    }
    foreach ($rel in $headerRels) {
        Copy-FromPin $rel (Join-Path $inc (Split-Path -Leaf $rel))
    }
    if ($WithPatchTargets) {
        foreach ($rel in $PATCH_TARGETS) {
            $dst = Join-Path $dir $rel
            New-Item -ItemType Directory -Force (Split-Path -Parent $dst) | Out-Null
            Copy-FromPin $rel $dst
        }
    }
    # CMakeLists.txt: the build scripts refuse without it, and a fixture that
    # looked like a checkout only to the extractor would be a half-fixture.
    Set-Content -LiteralPath (Join-Path $dir 'CMakeLists.txt') `
        -Value '# CAP-11B seeded fixture' -NoNewline
    if ($AsGitRepo) {
        git -C $dir init -q --initial-branch=main 2>&1 | Out-Null
        git -C $dir config core.autocrlf false 2>&1 | Out-Null
        git -C $dir config core.eol lf 2>&1 | Out-Null
        git -C $dir add -A 2>&1 | Out-Null
        # `commit.gpgsign=false` for THIS THROWAWAY FIXTURE only. It is not a
        # commit to this repository's history: a developer whose global config
        # signs every commit would otherwise see the whole case suite die on
        # `gpg: signing failed`, which is what happened on the dev host. No
        # gate, and no commit anyone reviews, is signed differently because of
        # this line.
        git -C $dir -c user.email='cap11b@example.invalid' -c user.name='cap11b' `
            -c commit.gpgsign=false commit -q -m 'seeded fixture' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "could not create the seeded git fixture $Name" }
    }
    return $dir
}
# EXACT MATCH, ONE OCCURRENCE. A seed that matched nothing would leave the
# fixture identical to the pin and the case would pass by testing nothing -
# the same discipline tools/regen-webview-binding.ps1 applies to its rewrites.
function Edit-Exact([string]$Path, [string]$From, [string]$To) {
    $text = [IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    $hits = ([regex]::Matches($text, [regex]::Escape($From))).Count
    if ($hits -ne 1) { throw "seed anchor found $hits times (expected 1) in $Path`: $From" }
    [IO.File]::WriteAllText($Path, $text.Replace($From, $To), [Text.UTF8Encoding]::new($false))
}

# --- run one case -------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]
function Invoke-Case([string]$Name, [string]$Expected, [string[]]$Arguments, [switch]$Unseeded) {
    $outDir = "build/cap11b/cases/$Name-out"
    $all = @('-NoProfile', '-File', 'test/cap11b/watch_upstream.ps1', '-OutDir', $outDir) + $Arguments
    $log = Join-Path $repoRoot "build/cap11b/cases/$Name.log"
    New-Item -ItemType Directory -Force (Join-Path $repoRoot $outDir) | Out-Null
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'pwsh'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $repoRoot
    foreach ($a in $all) { [void]$psi.ArgumentList.Add($a) }
    $p = [Diagnostics.Process]::Start($psi)
    $text = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    [IO.File]::WriteAllText($log, $text, [Text.UTF8Encoding]::new($false))

    # THE DRIVER MUST ALWAYS EXIT 0. A watcher whose exit code carried the
    # verdict would fail a job for news, which is the one thing the contract
    # forbids outright.
    if ($p.ExitCode -ne 0) { Violation "$Name`: the driver exited $($p.ExitCode); it must always exit 0" }

    $reportPath = Join-Path $repoRoot "$outDir/report.json"
    if (-not (Test-Path -LiteralPath $reportPath)) {
        Violation "$Name`: no report was written"
        [void]$results.Add([pscustomobject]@{ case = $Name; expected = $Expected; got = 'no_report' })
        return $null
    }
    $r = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($r.verdict -cne $Expected) {
        Violation "$Name`: verdict '$($r.verdict)', expected '$Expected' (findings: $($r.findings -join ' | '))"
    }
    # A SEEDED REPORT MUST SAY SO, and W8 - the one real run - must not.
    if ($Unseeded) {
        if ($r.seeded) { Violation "$Name`: a real run is stamped seeded:true" }
    }
    elseif (-not $r.seeded) { Violation "$Name`: the report is not stamped seeded:true" }
    if (-not $r.locks_unchanged) { Violation "$Name`: the report says a lock changed during the watch" }
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot "$outDir/report.md"))) {
        Violation "$Name`: no human report was written"
    }
    [void]$results.Add([pscustomobject]@{ case = $Name; expected = $Expected; got = $r.verdict })
    Write-Host "[cap11b] $Name -> $($r.verdict)"
    # A REPORT WITHOUT A DIFF IS A REPORT NO CASE MAY DEREFERENCE. Under
    # StrictMode `$r.diff.counts` on a null diff throws and kills the suite
    # mid-way, which turns one wrong verdict into no verdicts at all.
    if ($null -eq $r.diff -and $Expected -cne 'inconclusive' -and $Expected -cne 'build_failed') {
        Violation "$Name`: the report carries no diff, so nothing was compared"
        return $null
    }
    return $r
}

# =============================================================================
# W2 -- head IS the pin
# =============================================================================
$fx = New-Fixture 'w2-unchanged'
$r = Invoke-Case 'W2' 'unchanged' @('-Target', 'linux', '-SeedHeadRoot', $fx.Substring($repoRoot.Length + 1).Replace([char]92, [char]47), '-SeedSkipBuild')
if ($r) {
    if ($r.diff.counts.added -ne 0 -or $r.diff.counts.removed -ne 0 -or $r.diff.counts.changed -ne 0) {
        Violation "W2: the diff is not empty ($($r.diff.counts.added)/$($r.diff.counts.removed)/$($r.diff.counts.changed))"
    }
    if (-not $r.calibrated) { Violation 'W2: the projector was not calibrated on the pinned headers' }
    if ($r.signature_pin -cne 'ok') { Violation "W2: signature_pin reads '$($r.signature_pin)'" }
}

# =============================================================================
# W3 -- one added prototype
# =============================================================================
$fx = New-Fixture 'w3-additive'
Edit-Exact (Join-Path $fx 'core/include/webview/api.h') `
    'WEBVIEW_API const webview_version_info_t *webview_version(void);' `
    ("WEBVIEW_API const webview_version_info_t *webview_version(void);`n`n" +
     "WEBVIEW_API webview_error_t webview_set_icon(webview_t w, const char *path);")
$r = Invoke-Case 'W3' 'compatible_additive' @('-Target', 'linux', '-SeedHeadRoot', $fx.Substring($repoRoot.Length + 1).Replace([char]92, [char]47), '-SeedSkipBuild')
if ($r) {
    $named = @($r.diff.added | Where-Object { $_.name -ceq 'webview_set_icon' })
    if ($named.Count -ne 1) { Violation 'W3: the diff does not name webview_set_icon as added' }
    if ($r.diff.counts.removed -ne 0 -or $r.diff.counts.changed -ne 0) {
        Violation 'W3: an additive change produced removals or changes'
    }
    if ($r.signature_pin -cne 'ok') {
        Violation "W3: signature_pin must still compile against an additive header, reads '$($r.signature_pin)'"
    }
    if (-not ($r.findings -match 'webview_set_icon')) { Violation 'W3: no finding names the added prototype' }
}

# =============================================================================
# W4 -- one changed signature
# =============================================================================
$fx = New-Fixture 'w4-abi-break'
Edit-Exact (Join-Path $fx 'core/include/webview/api.h') `
    'WEBVIEW_API webview_error_t webview_navigate(webview_t w, const char *url);' `
    'WEBVIEW_API webview_error_t webview_navigate(webview_t w, const char *url, int flags);'
$r = Invoke-Case 'W4' 'abi_break' @('-Target', 'linux', '-SeedHeadRoot', $fx.Substring($repoRoot.Length + 1).Replace([char]92, [char]47), '-SeedSkipBuild')
if ($r) {
    if ($r.signature_pin -cne 'failed') {
        Violation "W4: signature_pin must FAIL to compile against a changed signature, reads '$($r.signature_pin)'"
    }
    if (-not $r.calibrated) {
        Violation 'W4: the calibration must pass first, or the failure is the tool and not upstream'
    }
    $named = @($r.diff.changed | Where-Object { $_.name -ceq 'webview_navigate' })
    if ($named.Count -ne 1) { Violation 'W4: the diff does not name webview_navigate as changed' }
    if (-not ($r.findings -match 'webview_navigate')) { Violation 'W4: no finding names the changed prototype' }
}

# =============================================================================
# W5c -- THE CONTROL, and it runs before the two drift cases on purpose.
#
# Without it, W5a and W5b prove nothing: a fixture whose line endings, missing
# files or stale copy made `git apply` fail for a reason unrelated to the seed
# would report `patch_drift` just as convincingly. This asserts that the
# UNEDITED fixture takes the pinned patch cleanly, so the two cases below can
# only be measuring their own edits. (Measured: the first version of this file
# had exactly that defect - CRLF fixtures made both drift cases pass on a
# context mismatch in a file neither of them touched.)
# =============================================================================
$fx = New-Fixture 'w5c-patch-control' -WithPatchTargets -AsGitRepo
$r = Invoke-Case 'W5c' 'unchanged' @('-Target', 'windows', '-SeedHeadRoot', $fx.Substring($repoRoot.Length + 1).Replace([char]92, [char]47), '-SeedSkipBuild')
if ($r) {
    if ($r.patch.outcome -cne 'clean') {
        Violation ("W5c CONTROL: the UNEDITED fixture reports patch outcome " +
            "'$($r.patch.outcome)' -- the two drift cases below would be measuring the fixture, not the seed")
    }
}

# =============================================================================
# W5a -- the patch's context moved: rejected
# =============================================================================
$fx = New-Fixture 'w5a-patch-rejected' -WithPatchTargets -AsGitRepo
Edit-Exact (Join-Path $fx 'core/include/webview/detail/backends/win32_edge.hh') `
    '    PathCombineW(userDataFolder, dataPath, currentExeName);' `
    '    PathCombineW(userDataFolder, dataPath, exeNameForProfile);'
$r = Invoke-Case 'W5a' 'patch_drift' @('-Target', 'windows', '-SeedHeadRoot', $fx.Substring($repoRoot.Length + 1).Replace([char]92, [char]47), '-SeedSkipBuild')
if ($r) {
    if ($r.patch.outcome -cne 'rejected') { Violation "W5a: patch outcome '$($r.patch.outcome)', expected 'rejected'" }
    if (-not $r.patch.hunk) { Violation 'W5a: the report carries no hunk for the rejection' }
    if ($r.patch.hunk -notmatch 'win32_edge\.hh') { Violation 'W5a: the hunk does not name the file that drifted' }
}

# =============================================================================
# W5b -- the patch still applies, somewhere else: offset
# =============================================================================
$fx = New-Fixture 'w5b-patch-offset' -WithPatchTargets -AsGitRepo
$hh = Join-Path $fx 'core/include/webview/detail/backends/win32_edge.hh'
$body = [IO.File]::ReadAllText($hh) -replace "`r`n", "`n"
[IO.File]::WriteAllText($hh, ("`n`n`n" + $body), [Text.UTF8Encoding]::new($false))
$r = Invoke-Case 'W5b' 'patch_drift' @('-Target', 'windows', '-SeedHeadRoot', $fx.Substring($repoRoot.Length + 1).Replace([char]92, [char]47), '-SeedSkipBuild')
if ($r) {
    if ($r.patch.outcome -cne 'offset') { Violation "W5b: patch outcome '$($r.patch.outcome)', expected 'offset'" }
    if ($r.patch.hunk -notmatch 'offset') { Violation 'W5b: the report does not record the offset git measured' }
}

# =============================================================================
# W6 -- the library build fails
# =============================================================================
$fx = New-Fixture 'w6-build-failed'
$tail = "ninja: build stopped: subcommand failed.`nwebview.cc:1:10: fatal error: 'WebKit/WebKit.h' file not found"
$r = Invoke-Case 'W6' 'build_failed' @('-Target', 'linux', '-SeedHeadRoot', $fx.Substring($repoRoot.Length + 1).Replace([char]92, [char]47), '-SeedBuildFailure', $tail)
if ($r) {
    if ($r.build.outcome -cne 'failed') { Violation "W6: build outcome '$($r.build.outcome)'" }
    if ($r.build.tail -notmatch 'fatal error') { Violation 'W6: the report carries no build log tail' }
}

# =============================================================================
# W7 -- the fetch is refused
# =============================================================================
$cause = "fatal: unable to access 'https://github.com/webview/webview/': Could not resolve host: github.com"
$r = Invoke-Case 'W7' 'inconclusive' @('-Target', 'linux', '-SeedFetchFailure', $cause)
if ($r) {
    if (-not ($r.findings -match 'Could not resolve host')) {
        Violation 'W7: inconclusive without naming the cause'
    }
    if ($r.head_commit) { Violation 'W7: a refused fetch must not report a head commit' }
    # THE POINT OF THE VERDICT: a run that measured nothing must never be
    # reported as a run that found nothing.
    if ($r.verdict -ceq 'unchanged') { Violation 'W7: inconclusive is indistinguishable from unchanged' }
}

# =============================================================================
# W8 -- THE REF PATH, FOR REAL, ON THIS LEG.
#
# Every case above passes `-SeedSkipBuild`, `-SeedBuildFailure` or
# `-SeedFetchFailure`, so `$buildOutcome -eq 'ok'` is unreachable in all of
# them - and the export check and the paired ABI probe are both guarded on it.
# That left the half of the watcher that actually compiles anything against a
# fetched tree executed by NO GATE: a broken ref build would surface only as a
# `build_failed` verdict on the weekly run, which the contract defines as
# legitimate news about upstream, on a job that concludes `success` either way.
#
# So this case runs the driver with NO seed at all, pointed at the PINNED
# commit as its ref. It is the same code path the weekly watcher takes -
# get-webview.ps1 -Ref, the platform build script --ref, the projection, both
# compiles, the export comparison, the paired probe - executed on this leg's
# own target, on every push, with an answer that is knowable in advance:
# head == the pin means `unchanged`.
#
# It is the one case that takes the network (one shallow fetch of a commit this
# leg has already fetched once) and the one that builds a library, which is why
# it is last.
# =============================================================================
$pinnedCommit = ''
foreach ($line in (Get-Content -LiteralPath (Join-Path $repoRoot 'webview.lock'))) {
    if ($line.Trim() -match '^commit\s*=\s*([0-9a-f]{40})$') { $pinnedCommit = $Matches[1]; break }
}
if (-not $pinnedCommit) { Violation 'webview.lock carries no 40-char commit pin' }
else {
    $r = Invoke-Case 'W8' 'unchanged' @('-Target', $legTarget, '-Ref', $pinnedCommit) -Unseeded
    if ($r) {
        if ($r.build.outcome -cne 'ok') {
            Violation "W8: the ref build did not produce a library (build.outcome='$($r.build.outcome)'): $($r.build.tail)"
        }
        if ($r.exports -cne 'ok') { Violation "W8: the export comparison reads '$($r.exports)'" }
        if ($r.abi_probe -cne 'ok') { Violation "W8: the paired ABI probe reads '$($r.abi_probe)'" }
        if ($r.signature_pin -cne 'ok') { Violation "W8: signature_pin reads '$($r.signature_pin)'" }
        if (-not $r.pinned_checkout_untouched) { Violation 'W8: the pinned checkout moved during a real watch' }
        if ($r.head_commit -cne $pinnedCommit) {
            Violation "W8: the ref resolved to '$($r.head_commit)', not the pinned '$pinnedCommit'"
        }
    }
}

# =============================================================================
# the vocabulary is covered, and the locks did not move
# =============================================================================
$seen = @($results | ForEach-Object { $_.got } | Sort-Object -Unique)
$want = @('abi_break', 'build_failed', 'compatible_additive', 'inconclusive', 'patch_drift', 'unchanged')
foreach ($v in $want) {
    if ($seen -cnotcontains $v) { Violation "no seeded case produced the verdict '$v'" }
}
$locksAfter = @{
    webview = Get-FileSha (Join-Path $repoRoot 'webview.lock')
    mormot  = Get-FileSha (Join-Path $repoRoot 'mormot.lock')
}
$locksUnchanged = ($locksBefore.webview -ceq $locksAfter.webview) -and ($locksBefore.mormot -ceq $locksAfter.mormot)
if (-not $locksUnchanged) { Violation 'a lock changed while the seeded cases ran' }

$record = [ordered]@{
    schema                 = 1
    cases                  = $results.ToArray()
    seeded_verdicts        = ($want -join ',')
    seeded_verdicts_observed = (($results | ForEach-Object { $_.got } | Sort-Object -Unique) -join ',')
    locks_unchanged_after_watch = $locksUnchanged.ToString().ToLowerInvariant()
    violations             = $violations.ToArray()
}
New-Item -ItemType Directory -Force (Join-Path $repoRoot 'build/cap11b') | Out-Null
[IO.File]::WriteAllText((Join-Path $repoRoot 'build/cap11b/cases.json'),
    (($record | ConvertTo-Json -Depth 8) -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))

Write-Host ''
foreach ($c in $results.ToArray()) { Write-Host ("[cap11b] {0,-4} expected {1,-20} got {2}" -f $c.case, $c.expected, $c.got) }
if ($violations.Count -gt 0) {
    Write-Host ''
    Write-Host "[cap11b] SEEDED CASES FAILED ($($violations.Count) violation(s))"
    exit 1
}
Write-Host "[cap11b] seeded cases PASS -- $($results.Count) cases, six verdicts, locks unchanged"
exit 0
