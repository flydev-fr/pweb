# CAP-11B: the upstream watcher's driver. ONE question, per target:
#
#   does the pinned PWeb binding still match upstream webview/webview head,
#   and if not, what changed?
#
# It answers with a REPORT and acts on nothing. It never re-pins, never
# regenerates the binding into the tree, never commits, never fails the matrix,
# and its output is never an input to a build. `webview.lock` and `mormot.lock`
# are digested before and after every run and the pair must be equal.
#
# THE JOB'S CONCLUSION IS `success` WHENEVER THE WATCHER RAN. This script exits
# 0 unconditionally - the verdict lives inside the report, and `inconclusive` is
# a legal verdict that always names its cause. A watcher that turned red because
# upstream moved would be reporting news as a regression.
#
# THE EIGHT STAGES, in the order the contract fixes:
#   1  record the pinned ref and patch digest from webview.lock
#   2  fetch upstream head - the ONE network step besides toolchain fetches
#   3  attempt the pinned platform patch on head, typed
#   4  build the library from head through the pinned build script + -Ref
#   5  compile signature_pin and the ABI probes; run the exported-symbol check
#   6  the API diff pinned -> head, from the headers, mechanically
#   7  the CAP-1 ABI checklist items that are runnable headless
#   8  the verdict, typed, with the evidence for each
#
# THE CALIBRATION IS THE LOAD-BEARING PART OF STAGE 5. Before anything is
# compiled against head, the SAME projector is run over the PINNED headers and
# the same pins are compiled against that. If the calibration fails, the tool is
# broken and the verdict is `inconclusive` - never `abi_break`.
#
#   pwsh test/cap11b/watch_upstream.ps1 -Target <t> [-Ref <ref>]
#
# The `-Seed*` inputs exist for test/cap11b/check_cap11b_cases.ps1 and each has
# to be named explicitly; a run with none of them takes the network and the
# toolchain. Every seeded run is stamped `seeded: true` in its report so it can
# never be read as a measurement of upstream.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('windows', 'linux', 'macos-x64', 'macos-arm64')]
    [string]$Target,
    [string]$Ref = 'HEAD',
    [string]$OutDir = 'build/cap11b/watch',
    # --- seams, seeded cases only ---------------------------------------------
    [string]$SeedHeadRoot,
    [string]$SeedFetchFailure,
    [string]$SeedBuildFailure,
    [switch]$SeedSkipBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

# --- THE VERDICT VOCABULARY. Six words, declared exactly once ----------------
# test/cap11b/check_watcher_contract.ps1 reads this array out of this file and
# publishes its digest as an evidence row compared across four targets, so four
# legs agreeing means they ran the same contract and not merely the same words.
$VERDICTS = @(
    'unchanged',
    'compatible_additive',
    'patch_drift',
    'abi_break',
    'build_failed',
    'inconclusive'
)
# Precedence, first match wins. The report keeps EVERY observation whichever
# one is chosen: a patch that drifted is still recorded on a run whose verdict
# is `abi_break`.
#
# WHY `inconclusive` IS NOT FIRST, which is where it started. `patch_drift`,
# `build_failed` and the removals and changes behind `abi_break` are measured
# WITHOUT the projector - git and the headers alone settle them - so a run
# whose Pascal toolchain could not calibrate still knows those three things for
# certain, and burying them under `inconclusive` would throw away the news the
# watcher exists to carry. What DOES depend on the projector is the claim that
# nothing broke: `compatible_additive` and `unchanged` are conclusions about
# compatibility, so `inconclusive` outranks both. (Measured on the dev host,
# whose FPC targets i386 and cannot compile the WIN64 platform block: the
# original order reported `inconclusive` for a seeded build failure and for a
# seeded patch rejection alike.)
$PRECEDENCE = @('abi_break', 'patch_drift', 'build_failed', 'inconclusive',
    'compatible_additive', 'unchanged')

# --- THE DECLARED PLATFORM PATCH SET -----------------------------------------
# Windows is the only target that patches upstream (CAP-4W). Linux and macOS
# carry none, and the repository proves it on every run with the two
# `deps/webview carries no <platform> patch` steps of the platform leg. A
# target with no declared patch reports `not_applicable`, never `patch_drift`.
$PLATFORM_PATCH = @{
    'windows'     = 'tools/cap4w/webview2-custom-scheme.patch'
    'linux'       = ''
    'macos-x64'   = ''
    'macos-arm64' = ''
}

# --- THE RATIFIED PAIRED-PROBE DELTA, per target -----------------------------
# MSVC types every C enum as signed int; gcc and clang pick unsigned when no
# enumerator is negative, and webview_hint_t / webview_native_handle_kind_t are
# both 0..3. This is the SAME allowance test/cap7l/check_abi.sh and
# test/cap7m/check_abi.sh ratified, quoted here rather than re-derived: exactly
# two lines, with exactly these values, and nothing else.
$PROBE_ALLOWED_DELTAS = @{
    'windows' = 0; 'linux' = 2; 'macos-x64' = 2; 'macos-arm64' = 2
}
$PROBE_ALLOWED_PAIRS = @(
    @('signed.webview_hint_t=0', 'signed.webview_hint_t=1'),
    @('signed.webview_native_handle_kind_t=0', 'signed.webview_native_handle_kind_t=1')
)

$seeded = [bool]($SeedHeadRoot -or $SeedFetchFailure -or $SeedBuildFailure -or $SeedSkipBuild)

$out = [IO.Path]::GetFullPath((Join-Path $repoRoot $OutDir))
# CLEARED, not merely created. Every stage below writes into this directory and
# several stages are conditional; a model, a projection or a diff left by an
# earlier run would be read by a later one that refused to produce its own, and
# the report would describe last week's head. The directory is under build/ by
# construction - the parameter is checked here rather than trusted.
if ($out -notmatch '[\\/]build[\\/]') {
    throw "the watcher writes only under build/: refusing OutDir '$OutDir'"
}
if (Test-Path -LiteralPath $out) { Remove-Item -Recurse -Force -LiteralPath $out }
New-Item -ItemType Directory -Force $out | Out-Null

$stages = New-Object System.Collections.Generic.List[object]
function Stage([string]$Name, [string]$Outcome, [string]$Detail) {
    [void]$stages.Add([pscustomobject]@{ stage = $Name; outcome = $Outcome; detail = $Detail })
    Write-Host "[cap11b] $Name : $Outcome$(if ($Detail) { " -- $Detail" })"
}
function Get-FileSha([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}
# Runs a command, captures BOTH streams into a log, returns the exit code.
# Stdout and stderr are merged deliberately: a build failure's cause is often
# on stderr and the report's tail has to carry it.
function Invoke-Logged([string]$File, [string[]]$Arguments, [string]$LogPath) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $File
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $repoRoot
    foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    $p = [Diagnostics.Process]::Start($psi)
    # BOTH PIPES ARE DRAINED CONCURRENTLY. Reading stdout to completion first
    # deadlocks the moment a child fills its stderr pipe buffer and blocks -
    # and cmake, fpc and git apply are exactly the children that write a lot to
    # stderr. The job timeout would be the only thing that ended it.
    $soTask = $p.StandardOutput.ReadToEndAsync()
    $seTask = $p.StandardError.ReadToEndAsync()
    [void][Threading.Tasks.Task]::WaitAll(@($soTask, $seTask))
    $p.WaitForExit()
    [IO.File]::WriteAllText($LogPath, ($soTask.Result + $seTask.Result), [Text.UTF8Encoding]::new($false))
    return $p.ExitCode
}
function Get-Tail([string]$LogPath, [int]$Lines = 40) {
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return '' }
    $all = @(Get-Content -LiteralPath $LogPath)
    if ($all.Count -le $Lines) { return ($all -join "`n") }
    return (($all[($all.Count - $Lines)..($all.Count - 1)]) -join "`n")
}

$findings = New-Object System.Collections.Generic.List[string]
function Find([string]$Verdict, [string]$Why) {
    [void]$findings.Add("$Verdict`t$Why")
    Write-Host "[cap11b] FINDING ($Verdict): $Why"
}

# =============================================================================
# 1. the pinned ref and the patch digest, from the lock
# =============================================================================
# EVERY LOCK, and the generated binding's config with them. The contract says
# "webview.lock, mormot.lock OR ANY PIN", and this repository pins six things.
# Digesting two of six would have left four unwatched for no reason.
$LOCK_FILES = @('webview.lock', 'mormot.lock', 'fpc.lock', 'pas2js.lock',
    'innosetup.lock', 'webview2-runtime.lock', 'src/lib/webview.chet')
function Get-PinDigests {
    $d = [ordered]@{}
    foreach ($f in $LOCK_FILES) { $d[$f] = Get-FileSha (Join-Path $repoRoot $f) }
    return $d
}
$webviewLock = Join-Path $repoRoot 'webview.lock'
$locksBefore = Get-PinDigests

# THE PINNED CHECKOUT IS NOT THE WATCHER'S TO TOUCH. `deps/` is git-ignored, so
# a `git status` over the repository says nothing about it - and the watcher
# does write inside `deps/`, into its OWN checkout. The distinction is the whole
# point, so it is measured on both sides: `deps/webview` must be at the pinned
# commit and clean when the watch ends, exactly as it was when it began.
$pinnedCheckout = Join-Path $repoRoot 'deps/webview'
function Get-PinnedCheckoutState {
    if (-not (Test-Path -LiteralPath (Join-Path $pinnedCheckout '.git'))) { return 'absent' }
    $head = (git -C $pinnedCheckout rev-parse HEAD 2>$null)
    $dirty = @(git -C $pinnedCheckout status --porcelain 2>$null)
    return "$($head)`:$($dirty.Count)"
}
$pinnedStateBefore = Get-PinnedCheckoutState

$lock = @{}
foreach ($line in (Get-Content -LiteralPath $webviewLock)) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    if ($t -notmatch '=') { continue }
    $k, $v = $t -split '=', 2
    $lock[$k.Trim()] = $v.Trim()
}
$pinnedCommit = $lock['commit']
$patchRel = $PLATFORM_PATCH[$Target]
$patchDigest = if ($patchRel) { Get-FileSha (Join-Path $repoRoot $patchRel) } else { '' }
$patchDigestPinned = if ($patchRel) { $lock['cap4w-patch-sha256'] } else { '' }
Stage 'pin' 'recorded' "commit=$pinnedCommit patch=$(if ($patchRel) { "$patchRel ($patchDigest)" } else { 'none declared' })"
if ($patchRel -and ($patchDigest -cne $patchDigestPinned)) {
    Find 'inconclusive' "the declared platform patch does not match its lock digest ($patchDigest vs $patchDigestPinned) -- the watcher would be measuring a patch nobody ratified"
}

# =============================================================================
# 2. fetch upstream head -- the ONE network step
# =============================================================================
$headRoot = ''
$headCommit = ''
$headDate = ''
if ($SeedFetchFailure) {
    Stage 'fetch' 'refused' $SeedFetchFailure
    Find 'inconclusive' "upstream head could not be fetched: $SeedFetchFailure"
}
elseif ($SeedHeadRoot) {
    $headRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot $SeedHeadRoot))
    $headCommit = 'seeded'
    $headDate = 'seeded'
    Stage 'fetch' 'seeded' $headRoot
}
else {
    $log = Join-Path $out 'fetch.log'
    $rc = Invoke-Logged 'pwsh' @('-NoProfile', '-File', 'tools/get-webview.ps1', '-Ref', $Ref) $log
    if ($rc -ne 0) {
        Stage 'fetch' 'refused' "tools/get-webview.ps1 -Ref $Ref exited $rc"
        Find 'inconclusive' "upstream head could not be fetched (exit $rc): $(Get-Tail $log 8)"
    }
    else {
        $headRoot = Join-Path $repoRoot 'deps/webview-watch'
        # `git` can succeed as a process and still print nothing here (an empty
        # checkout, a permission fault). `.Trim()` on that null throws, and the
        # driver's one hard promise is that it always exits 0.
        $rawCommit = (git -C $headRoot rev-parse HEAD 2>$null)
        # author-free on purpose: the watcher records WHAT changed and WHEN,
        # never who, and a report that carried author names would be publishing
        # personal data it has no use for.
        $rawDate = (git -C $headRoot log -1 --format=%cI 2>$null)
        if ([string]::IsNullOrWhiteSpace($rawCommit)) {
            $headRoot = ''
            Stage 'fetch' 'unreadable' 'the fetch reported success but the checkout has no HEAD'
            Find 'inconclusive' 'the head checkout has no readable HEAD after a successful fetch'
        }
        else {
            $headCommit = "$rawCommit".Trim()
            $headDate = if ([string]::IsNullOrWhiteSpace($rawDate)) { 'unknown' } else { "$rawDate".Trim() }
            Stage 'fetch' 'ok' "ref=$Ref commit=$headCommit date=$headDate"
        }
    }
}

# =============================================================================
# 3. the pinned platform patch, on head
# =============================================================================
$patchOutcome = 'not_attempted'
$patchHunk = ''
if ($headRoot) {
    if (-not $patchRel) {
        $patchOutcome = 'not_applicable'
        Stage 'patch' 'not_applicable' "no platform patch is declared for $Target"
    }
    elseif (-not (Test-Path -LiteralPath (Join-Path $headRoot '.git'))) {
        $patchOutcome = 'inconclusive'
        Stage 'patch' 'inconclusive' 'the head tree is not a git checkout, so git apply cannot judge the patch'
        Find 'inconclusive' 'the pinned platform patch could not be attempted: the head tree is not a git checkout'
    }
    elseif ((Resolve-Path -LiteralPath $headRoot).Path -ceq (Resolve-Path -LiteralPath $pinnedCheckout).Path) {
        # A RUNTIME GUARD, not a comment. The patch is applied for real below,
        # and the one tree it may never be applied to is the pinned checkout -
        # which would leave `deps/webview` patched for whatever ran next.
        $patchOutcome = 'refused'
        Stage 'patch' 'refused' 'the head tree resolved to the PINNED checkout; the watcher patches only its own'
        Find 'inconclusive' 'the head tree resolved to deps/webview -- the watcher refuses to patch the pinned checkout'
    }
    else {
        $patchFull = (Join-Path $repoRoot $patchRel)
        $strictLog = Join-Path $out 'patch-strict.log'
        $rcStrict = Invoke-Logged 'git' @('-C', $headRoot, 'apply', '--check',
            '--whitespace=error-all', $patchFull) $strictLog
        if ($rcStrict -ne 0) {
            $patchOutcome = 'rejected'
            $patchHunk = Get-Tail $strictLog 20
            Stage 'patch' 'rejected' 'the pinned patch does not apply to head'
            Find 'patch_drift' "the pinned $Target patch is rejected by head: $patchHunk"
        }
        else {
            # `--check` PASSES on a patch that lands at a different line: git
            # searches for the context and reports the displacement only while
            # actually applying. So the three-valued answer needs the real
            # apply, and `--verbose` is where git says "(offset N lines)".
            # The head checkout is a throwaway that get-webview.ps1 restores on
            # the next run, and patched is the shape production builds anyway.
            $applyLog = Join-Path $out 'patch-apply.log'
            $rcApply = Invoke-Logged 'git' @('-C', $headRoot, 'apply', '--verbose',
                '--whitespace=error-all', $patchFull) $applyLog
            $applyText = [IO.File]::ReadAllText($applyLog)
            if ($rcApply -ne 0) {
                $patchOutcome = 'apply_failed'
                $patchHunk = Get-Tail $applyLog 20
                Stage 'patch' 'apply_failed' $patchHunk
                Find 'inconclusive' 'the pinned patch passed --check and then failed to apply'
            }
            elseif ($applyText -match '\(offset ') {
                $patchOutcome = 'offset'
                $patchHunk = (($applyText -split "`n" | Where-Object { $_ -match '\(offset ' }) -join "`n")
                Stage 'patch' 'offset' 'the pinned patch still applies, but not where it used to'
                Find 'patch_drift' "the pinned $Target patch applies with an offset: $patchHunk"
            }
            else {
                $patchOutcome = 'clean'
                Stage 'patch' 'clean' 'the pinned patch applies to head at its recorded position'
            }
        }
    }
}

# =============================================================================
# 4. build the library from head, through the pinned script + its ref input
# =============================================================================
$buildOutcome = 'not_attempted'
$buildTail = ''
$headDist = ''
if ($headRoot -and -not $SeedSkipBuild) {
    if ($SeedBuildFailure) {
        $buildOutcome = 'failed'
        $buildTail = $SeedBuildFailure
        Stage 'build' 'failed' 'seeded build failure'
        Find 'build_failed' "the head library did not build: $buildTail"
    }
    else {
        $buildLog = Join-Path $out 'build.log'
        $rc = switch ($Target) {
            'windows' { Invoke-Logged 'pwsh' @('-NoProfile', '-File', 'tools/build-webview-dll.ps1', '-Ref', $Ref) $buildLog }
            'linux'   { Invoke-Logged 'bash' @('tools/build-webview-so.sh', '--ref', $Ref) $buildLog }
            'macos-x64'   { Invoke-Logged 'bash' @('tools/build-webview-dylib.sh', 'x86_64', '--ref', $Ref, '--clean') $buildLog }
            'macos-arm64' { Invoke-Logged 'bash' @('tools/build-webview-dylib.sh', 'arm64', '--ref', $Ref, '--clean') $buildLog }
        }
        if ($rc -ne 0) {
            $buildOutcome = 'failed'
            $buildTail = Get-Tail $buildLog 40
            Stage 'build' 'failed' "exit $rc"
            Find 'build_failed' "the head library did not build (exit $rc)"
        }
        else {
            $buildOutcome = 'ok'
            $headDist = Join-Path $repoRoot 'build/cap11b/webview-dist'
            Stage 'build' 'ok' $headDist
        }
    }
}
elseif ($SeedSkipBuild) {
    $buildOutcome = 'skipped'
    Stage 'build' 'skipped' 'seeded header-only run'
}

# =============================================================================
# 5+6. project, compile the pins, check the exports, diff the API
# =============================================================================
$pinnedModel = Join-Path $out 'model-pinned.json'
$headModel = Join-Path $out 'model-head.json'
$diffPath = Join-Path $out 'diff.json'
$projPinned = Join-Path $out 'proj-pinned'
$projHead = Join-Path $out 'proj-head'
$diff = $null
$calibrated = $false
$sigPinHead = 'not_attempted'
$probeOutcome = 'not_attempted'
$exportsOutcome = 'not_attempted'

function Invoke-Extract([string]$Root, [string]$OutFile, [string]$Tag) {
    $log = Join-Path $out "extract-$Tag.log"
    $rc = Invoke-Logged 'pwsh' @('-NoProfile', '-File', 'test/cap11b/extract_api.ps1',
        '-Root', $Root, '-Out', $OutFile) $log
    Write-Host (Get-Content -LiteralPath $log -Raw)
    return $rc
}
function Invoke-Project([string]$ModelFile, [string]$Dir, [string]$Tag) {
    $log = Join-Path $out "project-$Tag.log"
    $rc = Invoke-Logged 'pwsh' @('-NoProfile', '-File', 'test/cap11b/project_binding.ps1',
        '-Model', $ModelFile, '-OutDir', $Dir) $log
    Write-Host (Get-Content -LiteralPath $log -Raw)
    return $rc
}
# `-Cn` = compile, do not link. signature_pin.pas documents itself as a
# COMPILE-TIME gate ("CI therefore only COMPILES it"), and the exported-symbol
# check below is what proves the library still publishes the names.
function Invoke-SignaturePin([string]$UnitDir, [string]$Tag) {
    $log = Join-Path $out "sigpin-$Tag.log"
    $units = Join-Path $out "fpc-$Tag"
    New-Item -ItemType Directory -Force $units | Out-Null
    # `-o` names the output explicitly. Without it, `-Cn` leaves an `a.out`
    # object in the WORKING DIRECTORY - which is the repository root - and a
    # gate that measures a clean tree should not have to know about this
    # script's leftovers.
    $rc = Invoke-Logged 'fpc' @('-Sh', '-B', '-Cn', "-FU$units", "-Fu$UnitDir",
        '-Fideps/mormot2/src', "-FE$units", "-osignature_pin-$Tag",
        'test/core/signature_pin.pas') $log
    return @{ rc = $rc; log = $log }
}

if (-not $SeedFetchFailure -and $headRoot) {
    # --- calibration: the projector, proven on the PINNED headers -------------
    $rcP = Invoke-Extract (Join-Path $repoRoot 'deps/webview') $pinnedModel 'pinned'
    if ($rcP -ne 0) {
        Find 'inconclusive' 'the pinned headers could not be parsed -- the extractor refused'
    }
    else {
        $rcPP = Invoke-Project $pinnedModel $projPinned 'pinned'
        if ($rcPP -ne 0) {
            Find 'inconclusive' 'the projector refused the PINNED headers -- the tool is broken, not upstream'
        }
        else {
            $cal = Invoke-SignaturePin $projPinned 'pinned'
            if ($cal.rc -ne 0) {
                Stage 'calibrate' 'failed' (Get-Tail $cal.log 20)
                Find 'inconclusive' 'signature_pin does not compile against the PINNED projection -- the tool is broken, not upstream'
            }
            else {
                $calibrated = $true
                Stage 'calibrate' 'ok' 'signature_pin compiles against the pinned projection'
            }
        }
    }

    # --- head -----------------------------------------------------------------
    $rcH = Invoke-Extract $headRoot $headModel 'head'
    if ($rcH -ne 0) {
        Find 'inconclusive' 'head''s headers could not be parsed -- the extractor refused a declaration'
    }
    elseif ($calibrated) {
        $rcHP = Invoke-Project $headModel $projHead 'head'
        if ($rcHP -ne 0) {
            Find 'inconclusive' 'the projector refused head''s headers (an unmapped C type) -- the diff below still stands'
        }
        else {
            $sp = Invoke-SignaturePin $projHead 'head'
            if ($sp.rc -ne 0) {
                $sigPinHead = 'failed'
                Stage 'signature_pin' 'failed' (Get-Tail $sp.log 20)
                Find 'abi_break' "signature_pin does not compile against head: $(Get-Tail $sp.log 12)"
            }
            else {
                $sigPinHead = 'ok'
                # the COUNT HEAD DECLARES, not a constant: printing "17" on a
                # run whose head declares eighteen would be the report telling
                # the reader the opposite of what it measured
                $headFnCount = @((Get-Content -LiteralPath $headModel -Raw | ConvertFrom-Json).functions).Count
                Stage 'signature_pin' 'ok' "$headFnCount prototypes declared by head, all 17 pins accepted"
            }
        }
    }

    # --- the diff, whatever the compiles said ---------------------------------
    if ((Test-Path -LiteralPath $pinnedModel) -and (Test-Path -LiteralPath $headModel)) {
        $dlog = Join-Path $out 'diff.log'
        $rcD = Invoke-Logged 'pwsh' @('-NoProfile', '-File', 'test/cap11b/diff_api.ps1',
            '-Pinned', $pinnedModel, '-Head', $headModel, '-Out', $diffPath) $dlog
        Write-Host (Get-Content -LiteralPath $dlog -Raw)
        if ($rcD -ne 0 -or -not (Test-Path -LiteralPath $diffPath)) {
            Find 'inconclusive' "the diff tool did not produce a diff (exit $rcD): $(Get-Tail $dlog 8)"
        }
        else {
            $diff = Get-Content -LiteralPath $diffPath -Raw | ConvertFrom-Json
            # A REFUSED HEAD MODEL CANNOT SUPPORT `abi_break`. If the extractor
            # declined a declaration, everything it did not read looks REMOVED,
            # and reporting that as a break would be the parser blaming
            # upstream for its own blind spot. The diff is still published -
            # what it may not do is carry the most consequential verdict.
            $headComplete = ($rcH -eq 0)
            if (-not $headComplete) {
                Find 'inconclusive' 'head declarations were refused, so the diff below is partial and cannot be read as a break'
            }
            elseif ($diff.counts.removed -gt 0 -or $diff.counts.changed -gt 0) {
                $names = @()
                foreach ($x in $diff.removed) { $names += "removed $($x.kind) $($x.name)" }
                foreach ($x in $diff.changed) { $names += "changed $($x.kind) $($x.name)" }
                Find 'abi_break' ("the declared API is not backward compatible: " + ($names -join '; '))
            }
            elseif ($diff.counts.added -gt 0) {
                $names = @($diff.added | ForEach-Object { "added $($_.kind) $($_.name)" })
                Find 'compatible_additive' ("upstream added surface: " + ($names -join '; '))
            }
            # A HEADER APPEARING OR VANISHING IS NEWS IN ITS OWN RIGHT. Without
            # this a new public header carrying nothing the parser recognises
            # would produce `unchanged`, and a public header upstream DELETED
            # would too if its declarations had moved elsewhere.
            if ($headComplete -and @($diff.new_headers).Count -gt 0) {
                Find 'compatible_additive' ("upstream added a public header: " + (@($diff.new_headers) -join ', '))
            }
            if ($headComplete -and @($diff.gone_headers).Count -gt 0) {
                Find 'abi_break' ("a pinned public header is gone from head: " + (@($diff.gone_headers) -join ', '))
            }
        }
    }
}

# --- the exported-symbol check, against the library head produced ------------
# THE EXPORT SET IS READ AND TYPED HERE, NOT DELEGATED, AND THE REASON IS THE
# WHOLE POINT OF THE VERDICT VOCABULARY. The ratified per-platform gates assert
# EXACTLY the pinned seventeen ("the public surface may never grow an 18th
# export") because on the PINNED path an extra export means someone patched
# upstream. Against HEAD that same rule types a purely ADDITIVE upstream commit
# as a break - which would make `compatible_additive` unreachable on any run
# that actually builds, and would report news as a regression. Those gates keep
# their job on the pinned path, where the matrix runs them on every push; here
# the sets are compared and the difference is typed:
#
#   a pinned name that is gone           -> abi_break
#   an extra name head also DECLARES     -> compatible_additive
#   an extra name head does NOT declare  -> abi_break (an export with no
#                                           declaration is not a new API, it is
#                                           a surface nobody can bind against)
#   a non-webview_* export               -> macOS allows C++ typeinfo (_ZTI /
#                                           _ZTS), measured on run 31904189177;
#                                           nothing else, anywhere
#
# `test/cap11b/check_watcher_contract.ps1` cross-checks the entry-point list
# against test/cap7m/check_webview_exports.sh so the two cannot drift apart.
if ($buildOutcome -eq 'ok') {
    $elog = Join-Path $out 'exports.log'
    $lib = switch ($Target) {
        'windows' { 'build/cap11b/webview-dist/webview.dll' }
        'linux'   { 'build/cap11b/webview-dist/libwebview.so' }
        default   { 'build/cap11b/webview-dist/libwebview.dylib' }
    }
    $rcNm = switch ($Target) {
        'windows' { Invoke-Logged 'dumpbin' @('/nologo', '/exports', $lib) $elog }
        'linux'   { Invoke-Logged 'nm' @('-D', '--defined-only', '--format=posix', $lib) $elog }
        default   { Invoke-Logged 'nm' @('-gU', $lib) $elog }
    }
    if ($rcNm -ne 0) {
        $exportsOutcome = 'unreadable'
        Find 'inconclusive' "the export table of the head library could not be read: $(Get-Tail $elog 6)"
    }
    else {
        $raw = @(Get-Content -LiteralPath $elog)
        # `switch` is an expression here for readability; every branch returns a
        # non-empty list on a real library, and the `@(...)` below restores an
        # array from a $null the way the $badOther note explains.
        $symsRaw = switch ($Target) {
            'windows' {
                @($raw | ForEach-Object {
                    if ($_ -match '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)(?:\s+.*)?$') { $Matches[1] }
                })
            }
            'linux' { @($raw | Where-Object { $_.Trim() } | ForEach-Object { ($_ -split '\s+')[0] }) }
            default {
                # Mach-O prefixes every C symbol with one underscore; strip
                # exactly one before any comparison.
                @($raw | ForEach-Object { ($_ -split '\s+')[-1] } |
                    Where-Object { $_ -match '^_' } | ForEach-Object { $_.Substring(1) })
            }
        }
        $syms = @($symsRaw | Where-Object { $_ } | Sort-Object -Unique)
        $wv = @($syms | Where-Object { $_ -like 'webview_*' } | Sort-Object)
        $other = @($syms | Where-Object { $_ -notlike 'webview_*' })
        $pinnedNames = @()
        $headNames = @()
        if (Test-Path -LiteralPath $pinnedModel) {
            $pinnedNames = @((Get-Content -LiteralPath $pinnedModel -Raw | ConvertFrom-Json).functions |
                ForEach-Object { $_.name })
        }
        if (Test-Path -LiteralPath $headModel) {
            $headNames = @((Get-Content -LiteralPath $headModel -Raw | ConvertFrom-Json).functions |
                ForEach-Object { $_.name })
        }
        $missing = @($pinnedNames | Where-Object { $wv -cnotcontains $_ } | Sort-Object)
        $extra = @($wv | Where-Object { $pinnedNames -cnotcontains $_ } | Sort-Object)
        $extraDeclared = @($extra | Where-Object { $headNames -ccontains $_ })
        $extraUndeclared = @($extra | Where-Object { $headNames -cnotcontains $_ })
        # ASSIGNED DIRECTLY, never through an `if` expression: an empty `@()`
        # returned as the value of an `if` collapses to $null on the way out of
        # the pipeline, and `$null.Count` throws under StrictMode - which is
        # exactly the healthy case here, since a library with no unexpected
        # exports is what everyone wants.
        $badOther = @()
        if ($Target -eq 'macos-x64' -or $Target -eq 'macos-arm64') {
            $badOther = @($other | Where-Object { $_ -notmatch '^_ZT[IS]' })
        }
        else {
            $badOther = @($other)
        }

        if ($pinnedNames.Count -eq 0) {
            $exportsOutcome = 'not_compared'
            Find 'inconclusive' 'the pinned model was not produced, so the export surface had nothing to be compared against'
        }
        else {
            $exportsOutcome = 'ok'
            if ($missing.Count -gt 0) {
                $exportsOutcome = 'drifted'
                Find 'abi_break' ("the head library no longer exports: " + ($missing -join ','))
            }
            if ($extraUndeclared.Count -gt 0) {
                $exportsOutcome = 'drifted'
                Find 'abi_break' ("the head library exports a webview_* symbol head's headers do not declare: " +
                    ($extraUndeclared -join ','))
            }
            if ($badOther.Count -gt 0) {
                $exportsOutcome = 'drifted'
                Find 'abi_break' ("the head library exports a symbol that is neither an entry point nor permitted RTTI: " +
                    (($badOther | Select-Object -First 12) -join ','))
            }
            if ($extraDeclared.Count -gt 0 -and $exportsOutcome -eq 'ok') {
                $exportsOutcome = 'additive'
                Find 'compatible_additive' ("upstream exports new entry points: " + ($extraDeclared -join ','))
            }
        }
        Write-Host ("[cap11b] exports: {0} webview_*, {1} other; {2} missing, {3} extra ({4} declared)" -f `
            $wv.Count, $other.Count, $missing.Count, $extra.Count, $extraDeclared.Count)
    }
    Stage 'exports' $exportsOutcome (Get-Tail $elog 6)
}

# =============================================================================
# 7. the CAP-1 ABI checklist items that are runnable headless
# =============================================================================
# The paired probe measures what a header cannot state: enum WIDTH and
# SIGNEDNESS, record layout, and - at compile time inside abi_probe.pas - the
# two callback typedefs' conventions. It needs the built library to link, so it
# runs only on a run that built one.
$checklist = [ordered]@{
    'enum width and signedness'      = 'not_run'
    'record layout (PACKRECORDS C)'  = 'not_run'
    'callback typedef conventions'   = 'not_run'
    'calling conventions (17 pins)'  = $(if ($sigPinHead -eq 'ok') { 'pass' } elseif ($sigPinHead -eq 'failed') { 'fail' } else { 'not_run' })
    # MEASURED FROM THE DIFF, not merely from its existence. The row is about
    # whether an error code MOVED, so a diff that changed or removed an enum
    # member has to fail it - reading `pass` because a diff was produced was
    # exactly the shape of a vacuous check.
    'error-code values'              = $(
        if ($null -eq $diff) { 'not_run' }
        elseif (@(@($diff.changed) + @($diff.removed) |
                  Where-Object { $_ -and ($_.kind -like 'enum*') }).Count -gt 0) { 'fail' }
        else { 'pass' })
    'export surface (opaque handles)' = $(
        if ($exportsOutcome -eq 'ok') { 'pass' }
        elseif ($exportsOutcome -eq 'additive') { 'pass_additive' }
        elseif ($exportsOutcome -eq 'drifted') { 'fail' } else { 'not_run' })
}
if ($buildOutcome -eq 'ok' -and (Test-Path -LiteralPath $projHead)) {
    $probeDir = Join-Path $out 'probe'
    New-Item -ItemType Directory -Force $probeDir, (Join-Path $out 'fpc-probe') | Out-Null
    $inc = Join-Path $headRoot 'core/include'
    $cOut = Join-Path $probeDir ("abi_probe_c" + $(if ($Target -eq 'windows') { '.exe' } else { '' }))
    $clog = Join-Path $out 'probe-c.log'
    $rcC = switch ($Target) {
        'windows' { Invoke-Logged 'cl' @('/nologo', '/W4', '/WX', "/I$inc",
            'test/core/abi_probe.c', "/Fo$probeDir\", "/Fe$cOut") $clog }
        'linux'   { Invoke-Logged 'cc' @('-O1', '-Wall', '-Wextra', '-Werror', '-Wno-type-limits',
            "-I$inc", 'test/core/abi_probe.c', '-o', $cOut) $clog }
        default   { Invoke-Logged 'clang' @('-O1', '-Wall', '-Wextra', '-Werror', '-Wno-type-limits',
            "-I$inc", 'test/core/abi_probe.c', '-o', $cOut) $clog }
    }
    $plog = Join-Path $out 'probe-pascal.log'
    $fpcArgs = @('-Sh', '-B', "-FU$(Join-Path $out 'fpc-probe')", "-Fu$projHead",
        '-Fideps/mormot2/src', "-Fl$headDist", "-FE$probeDir", 'test/core/abi_probe.pas')
    if ($Target -eq 'linux') { $fpcArgs += '-k-rpath=$ORIGIN' }
    $rcPas = Invoke-Logged 'fpc' $fpcArgs $plog
    if ($rcC -ne 0 -or $rcPas -ne 0) {
        $probeOutcome = 'compile_failed'
        Stage 'abi_probe' 'compile_failed' ((Get-Tail $clog 8) + "`n" + (Get-Tail $plog 12))
        if ($rcPas -ne 0 -and $calibrated) {
            Find 'abi_break' "the paired ABI probe does not compile against head: $(Get-Tail $plog 10)"
        }
        elseif ($rcC -ne 0) {
            Find 'inconclusive' "the C side of the paired ABI probe did not compile: $(Get-Tail $clog 8)"
        }
    }
    else {
        $pasBin = Join-Path $probeDir ("abi_probe" + $(if ($Target -eq 'windows') { '.exe' } else { '' }))
        $cTxt = Join-Path $out 'abi_c.txt'; $pTxt = Join-Path $out 'abi_pascal.txt'
        $rc1 = Invoke-Logged $cOut @() $cTxt
        # the loader needs the library beside the binary on POSIX; the staged
        # SONAME copy is what DT_NEEDED names, exactly as the release layout does
        foreach ($f in @(Get-ChildItem -LiteralPath $headDist -File)) {
            Copy-Item -Force -LiteralPath $f.FullName -Destination $probeDir
        }
        $rc2 = Invoke-Logged $pasBin @() $pTxt
        if ($rc1 -ne 0 -or $rc2 -ne 0) {
            $probeOutcome = 'run_failed'
            Stage 'abi_probe' 'run_failed' "c=$rc1 pascal=$rc2"
            Find 'inconclusive' "a paired ABI probe exited nonzero (c=$rc1 pascal=$rc2)"
        }
        else {
            $cl = @(Get-Content -LiteralPath $cTxt); $pl = @(Get-Content -LiteralPath $pTxt)
            if ($cl.Count -lt 30) {
                $probeOutcome = 'too_few_facts'
                Find 'inconclusive' "the C probe emitted only $($cl.Count) facts -- expected at least 30"
            }
            elseif ($cl.Count -ne $pl.Count) {
                $probeOutcome = 'count_mismatch'
                Find 'abi_break' "the paired ABI probes disagree on fact COUNT: $($cl.Count) vs $($pl.Count)"
            }
            else {
                $unexpected = New-Object System.Collections.Generic.List[string]
                $allowed = 0
                for ($i = 0; $i -lt $cl.Count; $i++) {
                    if ($cl[$i] -ceq $pl[$i]) { continue }
                    $isAllowed = $false
                    foreach ($pair in $PROBE_ALLOWED_PAIRS) {
                        if (($cl[$i] -ceq $pair[0]) -and ($pl[$i] -ceq $pair[1])) { $isAllowed = $true }
                    }
                    if ($isAllowed) { $allowed++ } else { [void]$unexpected.Add("line $($i+1): C='$($cl[$i])' Pascal='$($pl[$i])'") }
                }
                if ($unexpected.Count -gt 0 -or $allowed -ne $PROBE_ALLOWED_DELTAS[$Target]) {
                    $probeOutcome = 'mismatch'
                    $why = if ($unexpected.Count -gt 0) { ($unexpected.ToArray() -join '; ') }
                           else { "expected exactly $($PROBE_ALLOWED_DELTAS[$Target]) documented signedness deltas, saw $allowed" }
                    Stage 'abi_probe' 'mismatch' $why
                    Find 'abi_break' "the paired ABI probes disagree beyond the ratified allowance: $why"
                }
                else {
                    $probeOutcome = 'ok'
                    $checklist['enum width and signedness'] = 'pass'
                    $checklist['record layout (PACKRECORDS C)'] = 'pass'
                    $checklist['callback typedef conventions'] = 'pass'
                    Stage 'abi_probe' 'ok' "$($cl.Count) facts, $allowed ratified delta(s)"
                }
            }
        }
    }
}

# =============================================================================
# 8. the verdict
# =============================================================================
$verdict = 'unchanged'
$reasons = @($findings.ToArray() | ForEach-Object { ($_ -split "`t", 2)[0] })
foreach ($v in $PRECEDENCE) {
    if ($reasons -ccontains $v) { $verdict = $v; break }
}
# `unchanged` is only ever said about a run that ACTUALLY COMPARED something.
# A run with no findings and no diff has measured nothing, and saying nothing
# changed would be the one dishonest answer available here.
if ($verdict -eq 'unchanged' -and $null -eq $diff) {
    $verdict = 'inconclusive'
    Find 'inconclusive' 'no API model was produced, so nothing was compared'
    $reasons = @($findings.ToArray() | ForEach-Object { ($_ -split "`t", 2)[0] })
}

$locksAfter = Get-PinDigests
$pinnedStateAfter = Get-PinnedCheckoutState
$pinnedCheckoutUntouched = ($pinnedStateBefore -ceq $pinnedStateAfter)
if (-not $pinnedCheckoutUntouched) {
    Find 'inconclusive' ("THE PINNED CHECKOUT MOVED DURING THE WATCH -- deps/webview was " +
        "'$pinnedStateBefore' and is now '$pinnedStateAfter'; the run is void")
}
$locksUnchanged = $true
foreach ($f in $LOCK_FILES) {
    if ($locksBefore[$f] -cne $locksAfter[$f]) { $locksUnchanged = $false }
}
if (-not $locksUnchanged) {
    # This cannot happen by design and is checked anyway: a watcher that moved a
    # pin would be the single worst failure this shard could have.
    Find 'inconclusive' 'A LOCK CHANGED DURING THE WATCH -- the run is void'
    $verdict = 'inconclusive'
}

$report = [ordered]@{
    schema            = 1
    capability        = 'CAP-11B'
    seeded            = $seeded
    target            = $Target
    ref_input         = $Ref
    pinned_commit     = $pinnedCommit
    head_commit       = $headCommit
    head_date         = $headDate
    verdict           = $verdict
    verdict_vocabulary = $VERDICTS
    patch             = [ordered]@{ declared = $patchRel; outcome = $patchOutcome; hunk = $patchHunk }
    build             = [ordered]@{ outcome = $buildOutcome; tail = $buildTail }
    calibrated        = $calibrated
    signature_pin     = $sigPinHead
    abi_probe         = $probeOutcome
    exports           = $exportsOutcome
    checklist         = $checklist
    diff              = $diff
    findings          = $findings.ToArray()
    stages            = $stages.ToArray()
    locks_unchanged   = $locksUnchanged
    locks_before      = $locksBefore
    locks_after       = $locksAfter
    pinned_checkout_untouched = $pinnedCheckoutUntouched
    pinned_checkout_before    = $pinnedStateBefore
    pinned_checkout_after     = $pinnedStateAfter
}
[IO.File]::WriteAllText((Join-Path $out 'report.json'),
    (($report | ConvertTo-Json -Depth 14) -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))

# --- the human half ----------------------------------------------------------
$md = New-Object System.Collections.Generic.List[string]
function MdLine([string]$Text) { [void]$md.Add($Text) }
MdLine "## Upstream watch - $Target - **$verdict**"
MdLine ''
if ($seeded) { MdLine '> **SEEDED RUN.** This report was produced from a seeded input by `test/cap11b/check_cap11b_cases.ps1`. It is not a measurement of upstream.'; MdLine '' }
MdLine '| | |'
MdLine '|---|---|'
MdLine "| pinned | ``$pinnedCommit`` |"
MdLine "| head | ``$headCommit`` ($headDate) |"
MdLine "| ref input | ``$Ref`` |"
MdLine "| platform patch | $(if ($patchRel) { "``$patchRel`` -- **$patchOutcome**" } else { 'none declared -- *not_applicable*' }) |"
MdLine "| build | **$buildOutcome** |"
MdLine "| signature_pin (17 prototypes) | **$sigPinHead** |"
MdLine "| paired ABI probe | **$probeOutcome** |"
MdLine "| exported symbols | **$exportsOutcome** |"
MdLine "| locks unchanged | **$locksUnchanged** |"
MdLine "| pinned checkout untouched | **$pinnedCheckoutUntouched** |"
MdLine ''
if ($null -ne $diff) {
    MdLine "### API diff (pinned -> head)"
    MdLine ''
    MdLine "$($diff.counts.added) added, $($diff.counts.removed) removed, $($diff.counts.changed) changed."
    MdLine ''
    if ($diff.counts.added -or $diff.counts.removed -or $diff.counts.changed) {
        MdLine '| change | kind | name | pinned | head |'
        MdLine '|---|---|---|---|---|'
        foreach ($x in $diff.removed) { MdLine "| removed | $($x.kind) | ``$($x.name)`` | ``$($x.pinned)`` | |" }
        foreach ($x in $diff.changed) { MdLine "| changed | $($x.kind) | ``$($x.name)`` | ``$($x.pinned)`` | ``$($x.head)`` |" }
        foreach ($x in $diff.added)   { MdLine "| added | $($x.kind) | ``$($x.name)`` | | ``$($x.head)`` |" }
        MdLine ''
    }
}
MdLine '### CAP-1 ABI checklist (headless items)'
MdLine ''
MdLine '| item | outcome |'
MdLine '|---|---|'
foreach ($k in $checklist.Keys) { MdLine "| $k | $($checklist[$k]) |" }
MdLine ''
if ($findings.Count -gt 0) {
    MdLine '### Findings'
    MdLine ''
    foreach ($f in $findings.ToArray()) {
        $parts = $f -split "`t", 2
        MdLine "- **$($parts[0])** - $($parts[1])"
    }
    MdLine ''
}
if ($buildTail) { MdLine '### Build log tail'; MdLine ''; MdLine '```'; MdLine $buildTail; MdLine '```'; MdLine '' }
if ($patchHunk) { MdLine '### Patch output'; MdLine ''; MdLine '```'; MdLine $patchHunk; MdLine '```'; MdLine '' }
MdLine '---'
MdLine 'This report changes nothing. The watcher never re-pins, never regenerates the binding into the tree, never commits, and its output is never an input to a build.'

$mdText = (($md.ToArray() -join "`n")) + "`n"
[IO.File]::WriteAllText((Join-Path $out 'report.md'), $mdText, [Text.UTF8Encoding]::new($false))
# THE JOB SUMMARY IS PUBLISHED ONLY WHEN THE WATCHER WORKFLOW ASKS FOR IT.
# Every child process inherits GITHUB_STEP_SUMMARY, and the case gate runs nine
# drivers on every ordinary CI leg - so without an explicit opt-in, nine reports
# headed `abi_break`, `patch_drift` and `build_failed` would land in the summary
# of a leg that measured nothing of the sort. `seeded` is not the right
# discriminator either: case W8 is a real, unseeded run and still must not
# publish. Only `.github/workflows/upstream-watch.yml` sets this, and
# test/cap11b/check_watcher_contract.ps1 requires that it does.
# The report file is always written; only the publication is conditional.
if ($env:GITHUB_STEP_SUMMARY -and $env:PWEB_WATCH_PUBLISH -eq '1') {
    [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $mdText, [Text.UTF8Encoding]::new($false))
}

Write-Host ''
Write-Host "[cap11b] VERDICT ($Target): $verdict"
Write-Host "[cap11b] report -> $(Join-Path $out 'report.json') / report.md"
# ALWAYS 0. The verdict is inside the report; the job's conclusion says only
# that the watcher ran.
exit 0
