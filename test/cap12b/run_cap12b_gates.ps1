# CAP-12B: the blob data plane, gated.
#
# The plane: bytes the runtime holds for one principal, served from the
# RESERVED prefix `pweb://app/_pweb/blob/<32 hex>` by the SAME production
# handler that serves the application's assets, with `PWEB_NATIVE_CSP`
# unchanged - byte for byte - on every one of its responses.
#
#   S1   the headless suite: the store, every ceiling proven to FIRE, the
#        token and Range grammars, the exchange a handler gets back and the
#        fetch door's envelope, with the decision corpus hashed so the four
#        targets can be compared
#   L1   the live harness: the SHIPPED store behind the SHIPPED handler in a
#        real window - whole and ranged reads, an <img>, typed-array upload
#        bodies at 1/16/256 MiB proven byte-exact by two independent
#        checksums, the foreign/unknown/released refusals, the 8 MiB window
#        against a real store, and every blob gone after a navigation
#   P1   the pack-time reservation: a dist carrying `_pweb/` is refused with
#        a typed cause naming the file, and the refusal is proven to FIRE
#   B1   what the built images do and do not carry
#
# Emits build/cap12b/cli-<target>.json for the CAP-7F aggregation.
#
# Usage: pwsh test/cap12b/run_cap12b_gates.ps1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$work = Join-Path $repoRoot 'build/cap12b'
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
function Sha256Text([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $b = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}
$target = TargetName
Row 'target' $target

# --- S1: the headless suite ---------------------------------------------------
$suite = Join-Path $work "bin/cap12btests$exeSuffix"
Require (Test-Path $suite) "S1: $suite is missing - run build_cap12b.ps1 first"
if (Test-Path $suite) {
    Write-Host '[CAP-12B] S1 headless suite'
    if ($IsWindows) { & $suite /noenter | Select-Object -Last 4 }
    else { & $suite | Select-Object -Last 4 }
    $suiteExit = $LASTEXITCODE
    Require ($suiteExit -eq 0) 'S1: the headless suite FAILED'
    # PASS/FAIL rather than true/false: the aggregator's $mustPass list
    # refuses a SKIP or a WAIVED standing where a verdict belongs, and it
    # compares against the word
    Row 'blob_suite' $(if ($suiteExit -eq 0) { 'PASS' } else { 'FAIL' })
    # THE DECISION CORPUS, hashed. Every line is the verdict of
    # platform-independent logic, so the four targets must agree on the
    # digest to the byte - and a target that quietly took a different branch
    # shows up here rather than in a row nobody reads.
    $corpus = Join-Path $work 'bin/blob-corpus.txt'
    if (Test-Path $corpus) {
        $text = ([System.IO.File]::ReadAllText($corpus) -replace "`r`n", "`n")
        Row 'blob_corpus_digest' (Sha256Text $text)
        Row 'blob_corpus_lines' ((($text -split "`n") | Where-Object { $_ -ne '' }).Count)
    } else {
        Require $false 'S1: the suite wrote no decision corpus'
        Row 'blob_corpus_digest' ''
        Row 'blob_corpus_lines' '0'
    }
} else {
    Row 'blob_suite' 'FAIL'
    Row 'blob_corpus_digest' ''
    Row 'blob_corpus_lines' '0'
}

# --- L1: the live harness -----------------------------------------------------
# It needs a window. A leg that cannot open one records `not_applicable` and
# says so; it never records a pass it did not make.
$liveExe = Join-Path $work "bin/bloblive$exeSuffix"
$liveOut = Join-Path $work ("live-" + $(if ($IsWindows) { 'windows' }
    elseif ($IsMacOS) { if ($target -eq 'macos-arm64') { 'macos-arm64' } else { 'macos-x64' } }
    else { 'linux' }) + '.json')
$live = $null
if (-not (Test-Path $liveExe)) {
    Require $false "L1: $liveExe is missing - run build_cap12b.ps1 first"
} else {
    Write-Host '[CAP-12B] L1 live harness'
    & $liveExe 2>&1 | Select-Object -Last 3
    $liveCode = $LASTEXITCODE
    Require ($liveCode -eq 0) 'L1: the live harness FAILED'
    if (Test-Path $liveOut) { $live = Get-Content $liveOut -Raw | ConvertFrom-Json }
}

function LiveRow([string]$Name) {
    if ($null -eq $live) { return $null }
    if ($null -eq $live.page) { return $null }
    if ($null -eq $live.page.phase1) { return $null }
    return $live.page.phase1.$Name
}

Row 'blob_plane_available' (Bool ($null -ne $live -and "$($live.overall)" -eq 'COMPLETE'))
Row 'blob_namespace' '_pweb/blob'
Row 'blob_url_prefix' $(if ($null -ne $live) { "$($live.prefix)" } else { '' })

# the whole-body row, offset-verified and carrying the whole policy block
$whole = LiveRow 'whole'
$wholeOk = ($null -ne $whole) -and ($whole.status -eq 200) -and
    ($whole.bytes -eq $whole.expected_bytes) -and ($whole.pattern_bad_at -eq -1) -and
    ("$($whole.content_type)" -eq 'text/plain; charset=utf-8') -and
    ("$($whole.cache_control)" -eq 'no-store') -and
    ("$($whole.nosniff)" -eq 'nosniff') -and ("$($whole.referrer_policy)" -eq 'no-referrer')
Require $wholeOk 'L1: a whole blob did not come back byte-exact with its policy block'
Row 'blob_whole_by_url' (Bool $wholeOk)

# THE CSP RIDES EVERY BLOB RESPONSE, 200, 206, 404, 405 and 416 alike, and it
# is compared against the SHIPPED constant rather than against a copy.
$cspRows = @('whole', 'range_single', 'range_suffix', 'range_declined',
    'range_unsatisfiable', 'upload_put_1m', 'foreign', 'released')
$cspOk = ($null -ne $live) -and ("$($live.csp)" -ne '')
foreach ($n in $cspRows) {
    $r = LiveRow $n
    if ($null -eq $r) { $cspOk = $false; continue }
    if ("$($r.csp)" -cne "$($live.csp)") {
        $cspOk = $false
        Write-Host "  the $n response carried a different CSP"
    }
}
Require $cspOk 'L1: a blob response did not carry the shipped CSP byte for byte'
Row 'blob_csp_byte_identical' (Bool $cspOk)

$single = LiveRow 'range_single'
$suffix = LiveRow 'range_suffix'
$rangeOk = ($null -ne $single) -and ($single.status -eq 206) -and
    ($single.bytes -eq 100) -and ($single.pattern_bad_at -eq -1) -and
    ("$($single.content_range)" -eq 'bytes 1000-1099/1048576') -and
    ("$($single.accept_ranges)" -eq 'bytes') -and
    ($null -ne $suffix) -and ($suffix.status -eq 206) -and
    ($suffix.bytes -eq 128) -and ($suffix.pattern_bad_at -eq -1) -and
    ("$($suffix.content_range)" -eq 'bytes 1048448-1048575/1048576')
Require $rangeOk 'L1: a ranged read was not answered 206 at the requested offset'
Row 'blob_range_206' (Bool $rangeOk)

$declined = LiveRow 'range_declined'
$declinedOk = ($null -ne $declined) -and ($declined.status -eq 200) -and
    ($declined.bytes -eq $declined.expected_bytes) -and
    ($declined.pattern_bad_at -eq -1) -and ($null -eq $declined.content_range)
Require $declinedOk 'L1: a declined Range was not answered 200 with the whole body'
Row 'blob_range_declined_200' (Bool $declinedOk)

$unsat = LiveRow 'range_unsatisfiable'
$unsatOk = ($null -ne $unsat) -and ($unsat.status -eq 416) -and
    ("$($unsat.content_range)" -eq 'bytes */1048576')
Require $unsatOk 'L1: an unsatisfiable Range was not answered 416 with a total'
Row 'blob_range_416' (Bool $unsatOk)

$img = LiveRow 'image'
$imgOk = ($null -ne $img) -and ($img.loaded -eq $true) -and ($img.width -eq 1)
Require $imgOk 'L1: an <img> did not decode from a blob URL'
Row 'blob_img' (Bool $imgOk)

# THE UPLOAD PATH, PROVEN BY TWO INDEPENDENT CHECKSUMS over the same bytes:
# the page computes crc32c in JavaScript, the handler computes it in Pascal
# over what ARRIVED, and the gate compares them. A length comparison would
# pass on a body that arrived rearranged.
$uploadOk = $true
$uploadMax = 0
foreach ($n in @('upload_put_1m', 'upload_post_16m', 'upload_put_256m')) {
    $u = LiveRow $n
    if (($null -eq $u) -or ($u.status -ne 405) -or ("$($u.allow)" -ne 'GET') -or
        ($null -eq $u.handler) -or
        ($u.handler.requestBodyBytes -ne $u.sent_bytes) -or
        ($u.handler.requestBodyComplete -ne $true) -or
        ("$($u.handler.requestBodyCrc32c)" -cne "$($u.sent_crc32c)") -or
        ("$($u.handler.error)" -ne 'blob_upload_not_enabled')) {
        $uploadOk = $false
        Write-Host "  $n did not arrive byte-exact and refused by name"
    } elseif ($u.sent_bytes -gt $uploadMax) { $uploadMax = $u.sent_bytes }
}
Require $uploadOk 'L1: a typed-array request body did not reach the handler byte-exact'
Row 'blob_body_bytes_256mib' (Bool ($uploadOk -and ($uploadMax -ge 268435456)))
Row 'blob_upload_refused_typed' (Bool $uploadOk)

# A FOREIGN TOKEN, AN UNKNOWN TOKEN AND A RELEASED TOKEN ARE ONE ANSWER.
# The gate compares the three responses to each other rather than to a
# constant: what matters is that nothing distinguishes them.
$foreign = LiveRow 'foreign'
$unknown = LiveRow 'unknown'
$released = LiveRow 'released'
$sameOk = ($null -ne $foreign) -and ($null -ne $unknown) -and ($null -ne $released) -and
    ($foreign.status -eq 404) -and ($unknown.status -eq 404) -and ($released.status -eq 404) -and
    ("$($foreign.body)" -ceq "$($unknown.body)") -and
    ("$($released.body)" -ceq "$($unknown.body)") -and
    ("$($foreign.content_type)" -ceq "$($unknown.content_type)") -and
    ($released.host_released -eq $true)
Require $sameOk 'L1: a foreign, an unknown and a released token were distinguishable'
Row 'blob_foreign_token_unknown' (Bool $sameOk)
Row 'blob_released_unresolvable' (Bool ($null -ne $released -and $released.status -eq 404))

# THE 8 MiB WINDOW AGAINST A REAL STORE - CAP-12A entry condition 6.3.3.
# The number is an OBSERVATION and never a threshold: it differs by an order
# of magnitude between engines by design, and a gate that failed on it would
# be a gate that fails when a runner is busy.
$win = LiveRow 'window'
$winOk = ($null -ne $win) -and ($win.blob_status -eq 200) -and
    ($win.blob_bytes -eq $win.expected_bytes) -and ($win.pattern_bad_at -eq -1) -and
    ($win.asset_status -eq 200)
Require $winOk 'L1: the 8 MiB window did not come back byte-exact beside an asset'
Row 'blob_window_ok' (Bool $winOk)
Row 'blob_window_ms' $(if ($null -ne $win) { [int][math]::Round($win.blob_at_ms) } else { -1 })
Row 'blob_window_asset_ms' $(if ($null -ne $win) { [int][math]::Round($win.asset_at_ms) } else { -1 })

$conc = LiveRow 'concurrent'
$concOk = ($null -ne $conc) -and ($conc.completed -eq $conc.n) -and ($conc.n -ge 32)
Require $concOk 'L1: 32 concurrent blob requests did not all complete'
Row 'blob_concurrent_bounded' (Bool $concOk)

# THE ASSET PLANE, UNCHANGED. The blob branch runs before the asset store is
# consulted, so the one thing that must be measured is that an ordinary
# asset carries exactly what it always did - and NOT the blob headers.
$asset = LiveRow 'asset_beside'
$assetOk = ($null -ne $asset) -and ($asset.status -eq 200) -and
    ("$($asset.content_type)" -eq 'text/javascript; charset=utf-8') -and
    ($null -eq $asset.accept_ranges) -and ($null -eq $asset.content_range) -and
    ("$($asset.cache_control)" -eq 'no-store')
Require $assetOk 'L1: an asset response changed beside a blob response'
Row 'blob_asset_unchanged' (Bool $assetOk)

# A RESERVED PATH THAT IS NOT A BLOB PATH is answered by the branch, so no
# store is ever consulted under the prefix.
$reserved = LiveRow 'reserved_not_a_blob'
$reservedOk = ($null -ne $reserved) -and ($reserved.status -eq 404)
Require $reservedOk 'L1: a reserved path that is not a blob path was not answered by the branch'
Row 'blob_reserved_intercepted' (Bool $reservedOk)

# EVERY BLOB OF THE WINDOW GONE AFTER A DOCUMENT REPLACEMENT, checked token
# by token by the page itself in its SECOND document.
$navOk = $false
if (($null -ne $live) -and ($null -ne $live.page) -and ($null -ne $live.page.phase2)) {
    $navOk = ($live.page.phase2.carried -eq $true) -and
        ($live.page_phases -ge 2) -and ($live.document_replacements -ge 2) -and
        ($live.page.phase2.asset_after_navigation.status -eq 200)
    foreach ($n in @('small', 'png', 'mid', 'window')) {
        $t = $live.page.phase2.tokens.$n
        if (($null -eq $t) -or ($t.status -ne 404)) {
            $navOk = $false
            Write-Host "  the $n blob survived the document replacement"
        }
    }
}
Require $navOk 'L1: a blob survived a document replacement'
Row 'blob_released_on_navigation' (Bool $navOk)

# THE CAP-9 ORDER: the harness closes the plane before it detaches anything,
# and asserts the store holds nothing once its last reader is gone.
Row 'blob_release_order' $(if (($null -ne $live) -and
    ($live.store_entries_after_close -eq 0)) { 'cap9' } else { 'unproven' })
Require (($null -ne $live) -and ($live.store_entries_after_close -eq 0)) `
    'L1: the store still held an entry after the plane closed and every reader went'

# NO CSP VIOLATION ANYWHERE. A blob URL is same-origin by construction, so a
# violation here would mean the namespace decision was wrong.
$violations = 0
if (($null -ne $live) -and ($null -ne $live.page) -and
    ($null -ne $live.page.csp_violations)) {
    $violations = @($live.page.csp_violations).Count
}
Require ($violations -eq 0) "L1: the page reported $violations CSP violation(s)"
Row 'blob_csp_violations' "$violations"

# --- P1: the pack-time reservation --------------------------------------------
# PROVEN TO FIRE, on a dist planted for the purpose, and then proven not to
# fire on the same dist without the plant. A refusal that has only ever been
# seen to accept has an unproven failure path.
$bundler = Join-Path $repoRoot "build/cap12b/bin/pwebbundle$exeSuffix"
if (-not (Test-Path $bundler)) {
    $bundler = Join-Path $repoRoot "build/cap10d1/bin/pwebbundle$exeSuffix"
}
$packOk = $false
$packClean = $false
if (Test-Path $bundler) {
    $dist = Join-Path $work 'packdist'
    if (Test-Path $dist) { Remove-Item -Recurse -Force $dist }
    New-Item -ItemType Directory -Force (Join-Path $dist 'assets'),
        (Join-Path $dist '_pweb/blob') | Out-Null
    Set-Content -NoNewline -Path (Join-Path $dist 'index.html') -Value `
        '<!doctype html><html><head><meta charset="utf-8"><title>t</title></head><body><script src="assets/app.js"></script></body></html>'
    Set-Content -NoNewline -Path (Join-Path $dist 'assets/app.js') -Value 'var x=1;'
    Set-Content -NoNewline -Path (Join-Path $dist '_pweb/blob/planted.bin') -Value 'planted'
    $out = & $bundler $dist (Join-Path $work 'refused.pwb') 2>&1 | Out-String
    $packOk = ($out -match 'reserved_prefix_in_bundle') -and
        ($out -match '_pweb/blob/planted.bin') -and
        (-not (Test-Path (Join-Path $work 'refused.pwb')))
    Require $packOk 'P1: the bundler did not refuse a dist carrying the reserved prefix'
    Remove-Item -Recurse -Force (Join-Path $dist '_pweb')
    $out2 = & $bundler $dist (Join-Path $work 'ok.pwb') 2>&1 | Out-String
    $packClean = (Test-Path (Join-Path $work 'ok.pwb'))
    Require $packClean 'P1: the same dist without the plant did not pack'
} else {
    Require $false 'P1: no pwebbundle binary to drive'
}
Row 'pack_refuses_pweb_prefix' (Bool $packOk)
Row 'pack_clean_dist_unaffected' (Bool $packClean)

# --- B1: what the images carry ------------------------------------------------
# The three units exist, and the URL namespace is spelled in exactly ONE of
# them. A second place that concatenated the prefix would be a second answer
# to the namespace question CAP-12A settled.
$srcFiles = @(Get-ChildItem -Path src, tools, sdk -Recurse -File -Include '*.pas' `
    -ErrorAction SilentlyContinue)
$prefixNamers = @()
foreach ($f in $srcFiles) {
    $rel = ($f.FullName.Substring($repoRoot.Length).TrimStart('\', '/')) -replace '\\', '/'
    if ([System.IO.File]::ReadAllText($f.FullName) -match ([regex]::Escape("pweb://app/") + "'\s*\+\s*PWEB_BLOB_PATH_PREFIX")) {
        $prefixNamers += $rel
    }
}
Require ($prefixNamers.Count -eq 1) `
    ("B1: the blob URL prefix is built in $($prefixNamers.Count) place(s): " +
     ($prefixNamers -join ', '))
Row 'blob_url_prefix_sources' ($prefixNamers -join ',')

Row 'blob_units_present' (Bool (
    (Test-Path 'src/assets/pweb.blobs.intf.pas') -and
    (Test-Path 'src/assets/pweb.blobs.memory.pas') -and
    (Test-Path 'src/assets/pweb.blobs.protocol.pas')))

# --- verdict ------------------------------------------------------------------
Row 'violations' "$($failures.Count)"
Row 'verdict' $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
$outFile = Join-Path $work "cli-$target.json"
($rows | ConvertTo-Json -Depth 4) + "`n" | Set-Content -NoNewline -Encoding utf8 $outFile
Write-Host ($rows | ConvertTo-Json -Depth 4)
Write-Host "[CAP-12B] wrote $outFile"
if ($failures.Count -gt 0) {
    Write-Host "[CAP-12B] GATES FAILED: $($failures.Count) violation(s)"
    exit 1
}
Write-Host '[CAP-12B] PASS'
exit 0
