# CAP-8B: the cross-target audit summary. MEASUREMENT ONLY, NEVER A GATE.
#
# WHAT THIS IS. The four CAP-8B probes (Windows/WebView2, Linux/WebKitGTK 4.1,
# macOS x86_64 and macOS arm64/WKWebView) each emit ONE schema-1 JSON document
# describing what their engine actually did. This script reads those documents
# and renders them as three side-by-side comparisons - bridge exposure,
# navigation coverage, active subresources - because the entire point of the
# exercise is a FIELD-BY-FIELD comparison across four engines, and four
# separate logs cannot be compared by reading them one after another.
#
# WHAT THIS DELIBERATELY IS NOT. It is not a gate and it never fails on a
# measurement it dislikes. A target whose file is absent prints MISSING, a
# report the page never produced prints NO-REPORT, and a divergence between
# engines is rendered rather than refused: "WebKit exposes the raw channel in
# a subframe where the shim is absent" is the KIND OF ANSWER this audit exists
# to obtain, so a summarizer that exited nonzero on it would be destroying the
# finding it was built to surface.
#
# THE ONE EXCEPTION, and the reason the three run_audit_* harnesses all call
# this script instead of carrying their own JSON reader: -RequireTarget <id>
# makes THAT target's document mandatory and structurally valid. A probe run
# that produced no parseable document is a failure OF THE INSTRUMENT, not a
# measurement, and each platform harness must be able to say so. Everything
# else stays non-fatal. One reader, one schema check, three platforms - a
# per-platform twin of a schema validator is exactly what this avoids.
#
# THE GOVERNING RULE OF EVERY CELL BELOW. A value that was DERIVED, DEFINED or
# ASSUMED is never printed in the shape of a MEASURED one. That rule is why
# this reader carries five states no earlier version had:
#
#   NOT-RUN   the target never started that case (no enter/ or leave/ beacon).
#             Distinct from NO-HOOK, which means the case DID run and no
#             native hook recorded it. Rendering the two identically was how
#             an earlier version printed an engine finding for
#             `trusted-navigate` - a case no probe has ever attempted.
#   n/a       user_initiated is JSON null: the engine was not asked, or the
#             hook cannot answer. Never rendered as false.
#   MISSING   the field is absent from the document altogether.
#   *         a value the reader normalized (a JSON boolean where other
#             targets sent a string), always accompanied by a divergence note.
#   ~         "did this case start" is unknowable because the target emitted
#             no beacons array.
#
# and why user_initiated is never compared across targets without its BASIS:
# Windows reports an engine gesture flag, Linux reports
# webkit_navigation_action_is_user_gesture, and macOS DERIVES the value from
# navigationType and cannot measure it at all. Three quantities in one row is
# not a comparison, so each target's own user_initiated_semantics sentence and
# the per-event user_initiated_basis values are printed beside the counts.
#
# The two taxonomies are also kept apart. A page case name (what the coverage
# driver called the thing it attempted) and a native case name (what
# CaseForUri attributed the navigation to) are DIFFERENT NAMESPACES that
# overlap by coincidence: the page's `redirect-out-of-pweb` is recorded
# natively as `redirect-first-leg`, and merging them printed "no hook saw the
# redirect" about a redirect the engine hooked. Tables 2a and 2b are therefore
# separate, and the probes' own setup navigations - `(host or startup
# navigation)` - are suppressed from both.
#
# Usage:
#   pwsh test/cap8b/summarize_audit.ps1 [-Path build/cap8b]
#        [-RequireTarget windows-x86_64] [-Detail]
#
# -Path is searched RECURSIVELY, so it accepts both the local build directory
# and a tree of downloaded CI artifacts (ev/cap8b-audit-<target>/...).
param(
    [string]$Path = 'build/cap8b',
    [ValidateSet('', 'windows-x86_64', 'linux-x86_64', 'macos-x86_64',
        'macos-arm64')]
    [string]$RequireTarget = '',
    [switch]$Detail
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# target id -> the file name its probe writes. The id is also what the
# document must DECLARE in its "target" field; a file that declares something
# else is refused rather than silently attributed to the file it was found in.
$targetFiles = [ordered]@{
    'windows-x86_64' = 'audit-windows-x86_64.json'
    'linux-x86_64'   = 'audit-linux-x86_64.json'
    'macos-x86_64'   = 'audit-macos-x86_64.json'
    'macos-arm64'    = 'audit-macos-arm64.json'
}

# Every DOCUMENT-LEVEL field the schema names. Presence is required; EMPTINESS
# IS NOT A FAILURE - a phase that could not report leaves its report empty,
# and that is a measurement ("the page never reported") rather than a broken
# instrument.
$requiredFields = @(
    'schema', 'target', 'engine', 'engine_version',
    'initial_source_before_navigate', 'csp_headers_emitted', 'candidate_csp',
    'user_initiated_semantics', 'download_hook_available',
    'native_arrivals', 'events', 'exposure_report', 'coverage_report',
    'csp_report', 'csp_meta_report', 'beacons', 'notes')

# The PER-EVENT fields the schema names. These are deliberately NOT in
# $requiredFields: that list decides whether a document is structurally a
# schema-1 audit at all, and -RequireTarget turns it into the harness's only
# hard failure. A probe that emits events without `policy` has produced a
# measurement this reader can still render - as "absent" - and refusing it
# would destroy the very comparison the reader exists for. So event-field
# conformance is RENDERED, per target, in the TARGETS table.
$requiredEventFields = @(
    'user_initiated_basis', 'policy', 'bootstrap_allowed', 'detail')

# The contexts kExposureJs builds, in the order the audit reasons about them:
# trusted top document, same-origin child, wrong-authority child, opaque
# data: child, parent-injected about:blank child (which INHERITS the parent
# origin and is therefore the most privileged shape an "empty" frame takes),
# and a separately opened window.
$exposureContexts = @(
    'top-trusted', 'iframe-same-origin', 'iframe-wrong-authority',
    'iframe-data', 'iframe-about-blank', 'window-open')

# The cases kCoverageJs runs, IN EXECUTION ORDER AND VERBATIM FROM THE THREE
# PROBES (the identical 28-case corpus is `await run('<name>'` in
# cap8b_audit_win.cpp, cap8b_audit_linux.c and cap8b_audit_macos.mm). This
# list is a rendering ORDER, never an assertion that a target ran them: what
# ran is decided per target from that target's own beacons.
#
# It must not contain a case no probe attempts. `trusted-navigate` used to sit
# here and produced a full row of engine findings for a navigation that has
# never been performed on any target.
$coverageCases = @(
    'script-location-external', 'script-window-open-external',
    'anchor-click-external', 'anchor-click-blank-external',
    'subframe-external', 'subframe-wrong-authority', 'subframe-trusted',
    'form-submit-external', 'redirect-out-of-pweb', 'meta-refresh-external',
    'download', 'scheme-http', 'scheme-file', 'scheme-data',
    'scheme-javascript', 'subframe-javascript', 'scheme-blob',
    'scheme-mailto', 'scheme-unknown', 'about-blank-late',
    'history-pushstate-back', 'fragment-same-document',
    'authority-uppercase', 'authority-suffix', 'authority-userinfo',
    'authority-port', 'authority-empty', 'reload-trusted-subframe')

# The rows kCspJs measures, in the order the CSP question is asked.
$cspRows = @(
    'same-origin-script', 'inline-script', 'external-script',
    'external-frame', 'trusted-frame', 'external-fetch', 'same-origin-fetch',
    'websocket', 'worker', 'eval', 'base-uri', 'object')

# The native attribution the probes give to their own setup navigations. It is
# not a case anybody asked for, so it is suppressed from the case tables and
# counted only in PHASES OBSERVED.
$hostCase = '(host or startup navigation)'

# The one authority the audit treats as trusted. Compared as an EXACT ORIGIN
# (see Test-TrustedOrigin) because the coverage corpus deliberately navigates
# to pweb://app.evil/, pweb://app@evil/ and pweb://app:8080/.
$trustedOrigin = 'pweb://app'

# --- small helpers -----------------------------------------------------------

# StrictMode makes a missing property a terminating error, which is right for
# code that knows its shape and wrong for a reader whose whole job is to
# tolerate documents that are incomplete in interesting ways.
function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $null
    try { $p = $Object.PSObject.Properties[$Name] } catch { return $null }
    if ($null -eq $p) { return $null }
    return $p.Value
}

# "The field is absent" and "the field is present and JSON null" are DIFFERENT
# measurements - the whole point of emitting user_initiated as null - and
# Get-Prop returns $null for both. This answers the first question alone.
function Test-HasProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    try { return ($null -ne $Object.PSObject.Properties[$Name]) }
    catch { return $false }
}

function Get-Cell {
    param($Value)
    if ($null -eq $Value) { return '' }
    # JSON booleans are rendered as the document spells them, not as
    # PowerShell spells them: this text gets read beside the raw documents.
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    return [string]$Value
}

# user_initiated has three states and only two of them are measurements:
#   true/false  the engine answered
#   n/a         the field is present and null - the engine was not asked, or
#               the hook exposes nothing (the basis says which)
#   MISSING     the probe does not emit the field at all
# false is NEVER printed for the last two.
function Get-UserInitiatedCell {
    param($Event)
    if (-not (Test-HasProp $Event 'user_initiated')) { return 'MISSING' }
    $v = Get-Prop $Event 'user_initiated'
    if ($null -eq $v) { return 'n/a' }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    return [string]$v
}

# EXACT ORIGIN, not a prefix. StartsWith('pweb://app') is true for
# pweb://app.evil/, pweb://app@evil/ and pweb://app:8080/ - every hostile
# authority the coverage corpus was built to try - so the prefix test rendered
# the most security-relevant escape this audit can observe as containment.
# Scheme and authority are compared case-insensitively (RFC 3986, and W5a
# measured the engine folding authority case before any hook sees it); the
# delimiter that must follow is /, # or ?, or nothing at all.
function Test-TrustedOrigin {
    param([string]$Href)
    if ([string]::IsNullOrEmpty($Href)) { return $false }
    if ($Href.Length -lt $trustedOrigin.Length) { return $false }
    if (-not $Href.StartsWith($trustedOrigin,
            [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($Href.Length -eq $trustedOrigin.Length) { return $true }
    $c = $Href[$trustedOrigin.Length]
    return (($c -eq '/') -or ($c -eq '#') -or ($c -eq '?'))
}

# MEASURED (windows-x86_64, WebView2 151.0.4129.86): the page reports arrive
# DOUBLE ENCODED, and deliberately so. Each probe stores the RAW webview_bind
# request for __cap8b_report, which is the JSON PARAMS ARRAY the shim sends -
# ["{...the page's own JSON...}"]. Keeping the argument array verbatim rather
# than the string inside it is what makes the field trustworthy: no harness
# ever re-encodes a page-supplied string, so nothing between the page and this
# reader can quietly alter what the page said.
#
# So this unwraps tolerantly and without assuming a depth: a JSON string that
# contains JSON, an array of such strings (a phase that reported more than
# once), or a plain object if a probe ever stores the inner form directly.
# Each field is parsed separately and its failure is confined to itself - an
# unparseable csp_report must not cost us the exposure table.
function Read-InnerReport {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return [pscustomobject]@{ State = 'absent'; Values = @() }
    }
    $parsed = $null
    try { $parsed = $Raw | ConvertFrom-Json }
    catch { return [pscustomobject]@{ State = 'unparsed'; Values = @() } }

    $values = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue($parsed)
    # Bounded, because the input is page-controlled: a report that nests
    # forever is a finding, not a reason to spin.
    $steps = 0
    while (($queue.Count -gt 0) -and ($steps -lt 256)) {
        $steps++
        $item = $queue.Dequeue()
        if ($null -eq $item) { continue }
        if ($item -is [string]) {
            $inner = $null
            try { $inner = $item | ConvertFrom-Json } catch { continue }
            $queue.Enqueue($inner)
            continue
        }
        if ($item -is [System.Collections.IEnumerable]) {
            foreach ($el in $item) { $queue.Enqueue($el) }
            continue
        }
        $values.Add($item)
    }
    if ($values.Count -eq 0) {
        return [pscustomobject]@{ State = 'unparsed'; Values = @() }
    }
    return [pscustomobject]@{ State = 'ok'; Values = $values.ToArray() }
}

# A phase may report more than once, so a field is read across every object
# the unwrap produced: the first non-null answer for a scalar, the
# concatenation for a list. "The page never said" and "the page said nothing
# useful" stay distinguishable.
function Get-ReportValue {
    param($Report, [string]$Name)
    if ($null -eq $Report) { return $null }
    if ($Report.State -ne 'ok') { return $null }
    foreach ($v in $Report.Values) {
        $p = Get-Prop $v $Name
        if ($null -ne $p) { return $p }
    }
    return $null
}

function Get-ReportList {
    param($Report, [string]$Name)
    $out = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Report) { return @() }
    if ($Report.State -ne 'ok') { return @() }
    foreach ($v in $Report.Values) {
        foreach ($e in @(Get-Prop $v $Name)) {
            if ($null -ne $e) { [void]$out.Add($e) }
        }
    }
    return $out.ToArray()
}

# The CSP driver reports its observables under a "rows" object.
function Get-ReportRow {
    param($Report, [string]$Name)
    if ($null -eq $Report) { return $null }
    if ($Report.State -ne 'ok') { return $null }
    foreach ($v in $Report.Values) {
        $rows = Get-Prop $v 'rows'
        if ($null -eq $rows) { continue }
        if (-not (Test-HasProp $rows $Name)) { continue }
        return [pscustomobject]@{ Present = $true; Value = (Get-Prop $rows $Name) }
    }
    return $null
}

function Get-ReportRowNames {
    param($Report)
    $names = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Report) { return @() }
    if ($Report.State -ne 'ok') { return @() }
    foreach ($v in $Report.Values) {
        $rows = Get-Prop $v 'rows'
        if ($null -eq $rows) { continue }
        foreach ($p in $rows.PSObject.Properties) {
            if (-not $names.Contains($p.Name)) { [void]$names.Add($p.Name) }
        }
    }
    return $names.ToArray()
}

# THE BEACONS ARE THE DID-IT-START EVIDENCE, and until this version the reader
# ignored them entirely. Each case emits pweb://app/beacon/enter/<name> before
# it runs and .../leave/<name> after, through the RESOURCE HANDLER rather than
# a binding, so the mark survives the document being torn down mid-case and
# grants no user gesture. EITHER mark is proof the case started: the real
# Windows run is missing enter/script-window-open-external and carries its
# leave, because the case navigated the driver before the image request landed.
function Read-Beacons {
    param($Doc)
    $set = New-Object System.Collections.Generic.HashSet[string]
    $raw = @(Get-Prop $Doc 'beacons')
    foreach ($b in $raw) {
        $s = [string]$b
        foreach ($tag in @('enter/', 'leave/')) {
            if ($s.StartsWith($tag)) { [void]$set.Add($s.Substring($tag.Length)) }
        }
    }
    return [pscustomobject]@{
        Present = (Test-HasProp $Doc 'beacons')
        Cases   = $set
        Raw     = $raw
        Count   = $raw.Count
    }
}

# THE MARKER IS STICKY AND THE READER MUST UNDO THAT. Every driver reports
# `marker: (window.__cap8b_marker || null)`, and only scheme-javascript ever
# sets it - so every case AFTER it inherits the value. In the real Windows
# document 14 of 28 cases carry marker=jsurl; reading each row in isolation
# credits 13 innocent cases with executing a javascript: URL. The marker is
# therefore treated as SET only where it CHANGED from the previous case, which
# requires walking the cases in the order the page reported them.
function Read-CoverageCases {
    param($Coverage)
    $tbl = [ordered]@{}
    $prev = $null
    $index = 0
    foreach ($case in @(Get-ReportList $Coverage 'cases')) {
        $name = [string](Get-Prop $case 'name')
        if ([string]::IsNullOrEmpty($name)) { continue }
        $markerRaw = Get-Prop $case 'marker'
        $marker = $null
        if ($null -ne $markerRaw) { $marker = [string]$markerRaw }
        $changed = ($marker -ne $prev)
        $prev = $marker
        $index++
        if (-not $tbl.Contains($name)) {
            $threwRaw = Get-Prop $case 'threw'
            $tbl[$name] = [pscustomobject]@{
                Name          = $name
                Index         = $index
                Threw         = $(if ($null -eq $threwRaw) { $null } else { [string]$threwRaw })
                Href          = [string](Get-Prop $case 'href')
                Marker        = $marker
                MarkerChanged = $changed
            }
        }
    }
    return $tbl
}

function Write-Grid {
    param([string[]]$Columns, [object[]]$Rows)
    $count = $Columns.Count
    $widths = @()
    for ($i = 0; $i -lt $count; $i++) { $widths += $Columns[$i].Length }
    foreach ($row in $Rows) {
        for ($i = 0; $i -lt $count; $i++) {
            $len = (Get-Cell $row[$i]).Length
            if ($len -gt $widths[$i]) { $widths[$i] = $len }
        }
    }
    $head = @()
    $rule = @()
    for ($i = 0; $i -lt $count; $i++) {
        $head += $Columns[$i].PadRight($widths[$i])
        $rule += ('-' * $widths[$i])
    }
    Write-Host ('  ' + (($head -join '  ').TrimEnd()))
    Write-Host ('  ' + ($rule -join '  '))
    foreach ($row in $Rows) {
        $line = @()
        for ($i = 0; $i -lt $count; $i++) {
            $line += (Get-Cell $row[$i]).PadRight($widths[$i])
        }
        Write-Host ('  ' + (($line -join '  ').TrimEnd()))
    }
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "=== $Title"
    Write-Host ''
}

# --- load ---------------------------------------------------------------------

$searchRoot = $Path
if (-not (Test-Path -LiteralPath $searchRoot)) {
    Write-Host "[CAP-8B] audit directory does not exist: $searchRoot"
    if ($RequireTarget) {
        Write-Host "[CAP-8B] REQUIRED TARGET UNAVAILABLE: $RequireTarget"
        exit 1
    }
    exit 0
}
$searchRoot = (Resolve-Path -LiteralPath $searchRoot).Path

$audits = [ordered]@{}
$problems = [ordered]@{}
foreach ($t in $targetFiles.Keys) {
    $audits[$t] = $null
    $problems[$t] = ''
}

foreach ($t in $targetFiles.Keys) {
    $name = $targetFiles[$t]
    $found = @(Get-ChildItem -LiteralPath $searchRoot -Recurse -File `
            -Filter $name -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) {
        $problems[$t] = 'MISSING'
        continue
    }
    if ($found.Count -gt 1) {
        # Ambiguity is never resolved by picking one: two documents claiming
        # the same target is exactly the state in which a stale measurement
        # gets quoted as if it were this run's.
        $problems[$t] = "AMBIGUOUS ($($found.Count) files named $name under $searchRoot)"
        continue
    }
    $file = $found[0].FullName
    try {
        $doc = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    }
    catch {
        $problems[$t] = "UNPARSEABLE ($file)"
        continue
    }
    $missing = @()
    foreach ($f in $requiredFields) {
        if ($null -eq $doc.PSObject.Properties[$f]) { $missing += $f }
    }
    if ($missing.Count -gt 0) {
        $problems[$t] = "FIELDS MISSING: $($missing -join ',')"
        continue
    }
    if ("$(Get-Prop $doc 'schema')" -cne '1') {
        $problems[$t] = "SCHEMA MISMATCH: schema=$(Get-Prop $doc 'schema'), expected 1"
        continue
    }
    if ("$(Get-Prop $doc 'target')" -cne $t) {
        $problems[$t] = "TARGET IDENTITY MISMATCH: $name declares '$(Get-Prop $doc 'target')', expected '$t'"
        continue
    }
    $coverage = Read-InnerReport ([string](Get-Prop $doc 'coverage_report'))
    $audits[$t] = [pscustomobject]@{
        File      = $file
        Doc       = $doc
        Exposure  = (Read-InnerReport ([string](Get-Prop $doc 'exposure_report')))
        Coverage  = $coverage
        Cases     = (Read-CoverageCases $coverage)
        Csp       = (Read-InnerReport ([string](Get-Prop $doc 'csp_report')))
        CspMeta   = (Read-InnerReport ([string](Get-Prop $doc 'csp_meta_report')))
        Beacons   = (Read-Beacons $doc)
    }
}

$present = @($targetFiles.Keys | Where-Object { $null -ne $audits[$_] })
$columns = @('') + @($targetFiles.Keys)

Write-Host ''
Write-Host '################################################################'
Write-Host '# CAP-8B PRIVILEGED-NAVIGATION AUDIT - cross-target measurement #'
Write-Host '# MEASUREMENT ONLY. Nothing here gates; nothing here is policy. #'
Write-Host '################################################################'
Write-Host ''
Write-Host "source: $searchRoot"
Write-Host "targets present: $($present.Count)/$($targetFiles.Count)"

# --- 0. what ran --------------------------------------------------------------

# Which of the per-event schema fields this target's probe actually emits.
# Rendered rather than enforced: see $requiredEventFields.
function Get-EventFieldConformance {
    param($Doc)
    $events = @(Get-Prop $Doc 'events')
    if ($events.Count -eq 0) { return 'no events' }
    $absent = @()
    $partial = @()
    foreach ($f in $requiredEventFields) {
        $n = 0
        foreach ($ev in $events) { if (Test-HasProp $ev $f) { $n++ } }
        if ($n -eq 0) { $absent += $f }
        elseif ($n -lt $events.Count) { $partial += "$f($n/$($events.Count))" }
    }
    if (($absent.Count -eq 0) -and ($partial.Count -eq 0)) { return 'complete' }
    $parts = @()
    if ($absent.Count -gt 0) { $parts += "ABSENT: $($absent -join ',')" }
    if ($partial.Count -gt 0) { $parts += "PARTIAL: $($partial -join ',')" }
    return ($parts -join '; ')
}

Write-Section 'TARGETS'
$rows = @()
foreach ($field in @(
        @{ Label = 'status'; Get = { param($a, $t) if ($null -eq $a) { $problems[$t] } else { 'present' } } },
        @{ Label = 'engine'; Get = { param($a, $t) Get-Prop $a.Doc 'engine' } },
        @{ Label = 'engine_version'; Get = { param($a, $t) Get-Prop $a.Doc 'engine_version' } },
        @{ Label = 'initial source'; Get = { param($a, $t) Get-Prop $a.Doc 'initial_source_before_navigate' } },
        @{ Label = 'csp headers emitted'; Get = { param($a, $t) Get-Prop $a.Doc 'csp_headers_emitted' } },
        @{ Label = 'download hook available'; Get = { param($a, $t)
                if (-not (Test-HasProp $a.Doc 'download_hook_available')) { 'MISSING' }
                else { Get-Prop $a.Doc 'download_hook_available' } } },
        @{ Label = 'nav events recorded'; Get = { param($a, $t) @(Get-Prop $a.Doc 'events').Count } },
        @{ Label = 'per-event schema fields'; Get = { param($a, $t) Get-EventFieldConformance $a.Doc } },
        @{ Label = 'beacons recorded'; Get = { param($a, $t)
                if (-not $a.Beacons.Present) { 'MISSING' }
                else { "$($a.Beacons.Count) ($($a.Beacons.Cases.Count) case(s) started)" } } },
        @{ Label = 'notes recorded'; Get = { param($a, $t) @(Get-Prop $a.Doc 'notes').Count } })) {
    $row = @($field.Label)
    foreach ($t in $targetFiles.Keys) {
        $a = $audits[$t]
        if ($null -eq $a) {
            if ($field.Label -eq 'status') { $row += $problems[$t] } else { $row += 'MISSING' }
        }
        else {
            $row += (Get-Cell (& $field.Get $a $t))
        }
    }
    $rows += , $row
}
Write-Grid -Columns $columns -Rows $rows

# The candidate CSP must be the SAME STRING on every target or the four
# measurements are not measuring the same policy. Rendered, never refused.
Write-Host ''
$cspStrings = @{}
foreach ($t in $present) { $cspStrings[$t] = [string](Get-Prop $audits[$t].Doc 'candidate_csp') }
$distinctCsp = @($cspStrings.Values | Sort-Object -Unique)
if ($present.Count -eq 0) {
    Write-Host '  candidate CSP: no target reported'
}
elseif ($distinctCsp.Count -eq 1) {
    Write-Host "  candidate CSP (identical on $($present.Count) target(s)):"
    Write-Host "    $($distinctCsp[0])"
}
else {
    Write-Host '  candidate CSP: DIVERGENT ACROSS TARGETS - the four measurements'
    Write-Host '  are not measuring the same policy string:'
    foreach ($t in $present) { Write-Host "    ${t}: $($cspStrings[$t])" }
}

# --- 1. bridge exposure -------------------------------------------------------

Write-Section 'QUESTION 1 - BRIDGE EXPOSURE (context x target)'
Write-Host '  cell = <shim>/<raw>/<native shim arrivals>+<native raw arrivals>'
Write-Host '    shim  Y = window.__pweb_invoke is a function in that context'
Write-Host '    raw   Y = the engine''s lowest transport is reachable there'
Write-Host '          (chrome.webview on WebView2, webkit.messageHandlers on WebKit)'
Write-Host '    native = arrivals AT THE NATIVE BINDING, which is the only'
Write-Host '          authority on what actually crossed; the page''s own'
Write-Host '          optimism is never taken as reach'
Write-Host '    -     = that context produced no record at all'
Write-Host ''

$observedContexts = New-Object System.Collections.Generic.List[string]
foreach ($c in $exposureContexts) { [void]$observedContexts.Add($c) }
foreach ($t in $present) {
    foreach ($rec in @(Get-ReportList $audits[$t].Exposure 'records')) {
        $ctx = [string](Get-Prop $rec 'ctx')
        if ($ctx -and -not $observedContexts.Contains($ctx)) {
            [void]$observedContexts.Add($ctx)
        }
    }
}

# One lookup used by every exposure table below.
function Get-ExposureRecord {
    param($Audit, [string]$Ctx)
    foreach ($candidate in @(Get-ReportList $Audit.Exposure 'records')) {
        if ([string](Get-Prop $candidate 'ctx') -eq $Ctx) { return $candidate }
    }
    return $null
}

$rows = @()
foreach ($ctx in $observedContexts) {
    $row = @($ctx)
    foreach ($t in $targetFiles.Keys) {
        $a = $audits[$t]
        if ($null -eq $a) { $row += 'MISSING'; continue }
        $exp = $a.Exposure
        if ($exp.State -eq 'absent') { $row += 'NO-REPORT'; continue }
        if ($exp.State -eq 'unparsed') { $row += 'UNPARSED'; continue }
        $rec = Get-ExposureRecord $a $ctx
        $arrivals = Get-Prop $a.Doc 'native_arrivals'
        $nShim = Get-Prop $arrivals "shim.$ctx"
        $nRaw = Get-Prop $arrivals "raw.$ctx"
        if ($null -eq $nShim) { $nShim = 0 }
        if ($null -eq $nRaw) { $nRaw = 0 }
        if ($null -eq $rec) {
            # No record, but native may still have been reached - which is
            # itself a finding worth showing rather than hiding behind a dash.
            $row += "-/-/$nShim+$nRaw"
            continue
        }
        $shim = if ([string](Get-Prop $rec 'shim') -eq 'function') { 'Y' } else { 'n' }
        $raw = if ((Get-Prop $rec 'raw') -eq $true) { 'Y' } else { 'n' }
        $row += "$shim/$raw/$nShim+$nRaw"
    }
    $rows += , $row
}
Write-Grid -Columns $columns -Rows $rows

# [1b] THE ORIGIN EACH CONTEXT REPORTED FOR ITSELF, and the raw typeof of the
# SDK object. Measured by the probes and never rendered until now: "the shim
# is a function in a context whose origin is null" is the single sentence that
# decides whether an opaque frame can be trusted, and it cannot be read off
# the Y/n table at all.
Write-Host ''
Write-Host '  [1b] location.origin and typeof window.__webview__, as each context reported them'
Write-Host '       cell = <origin> / <typeof __webview__>'
Write-Host ''
$rows = @()
foreach ($ctx in $observedContexts) {
    $row = @($ctx)
    foreach ($t in $targetFiles.Keys) {
        $a = $audits[$t]
        if ($null -eq $a) { $row += 'MISSING'; continue }
        if ($a.Exposure.State -ne 'ok') { $row += $a.Exposure.State.ToUpperInvariant(); continue }
        $rec = Get-ExposureRecord $a $ctx
        if ($null -eq $rec) { $row += '-'; continue }
        $origin = Get-Prop $rec 'origin'
        $wv = Get-Prop $rec 'webview'
        $originCell = if ($null -eq $origin) { 'MISSING' } else { [string]$origin }
        $wvCell = if ($null -eq $wv) { 'MISSING' } else { [string]$wv }
        $row += "$originCell / $wvCell"
    }
    $rows += , $row
}
Write-Grid -Columns $columns -Rows $rows

# [1c] What THREW while probing. A shim that is present but throws is a very
# different measurement from a shim that is absent, and both were being
# collapsed into 'n'.
Write-Host ''
Write-Host '  [1c] throws recorded while probing (cell = shim:<x> raw:<y>; "." = neither threw)'
Write-Host ''
$rows = @()
foreach ($ctx in $observedContexts) {
    $row = @($ctx)
    foreach ($t in $targetFiles.Keys) {
        $a = $audits[$t]
        if ($null -eq $a) { $row += 'MISSING'; continue }
        if ($a.Exposure.State -ne 'ok') { $row += $a.Exposure.State.ToUpperInvariant(); continue }
        $rec = Get-ExposureRecord $a $ctx
        if ($null -eq $rec) { $row += '-'; continue }
        $st = Get-Prop $rec 'shimThrew'
        $rt = Get-Prop $rec 'rawThrew'
        if (($null -eq $st) -and ($null -eq $rt)) { $row += '.'; continue }
        $parts = @()
        if ($null -ne $st) { $parts += "shim:$st" }
        if ($null -ne $rt) { $parts += "raw:$rt" }
        $row += ($parts -join ' ')
    }
    $rows += , $row
}
Write-Grid -Columns $columns -Rows $rows

# The structural facts the exposure orchestrator reports about itself.
# openThrew is the third one and was never rendered: "window.open threw" and
# "window.open succeeded but the popup never reported" are opposite findings
# about the same empty row of the context table.
Write-Host ''
$rows = @()
foreach ($field in @('blankInjected', 'openedWindow', 'openThrew')) {
    $row = @($field)
    foreach ($t in $targetFiles.Keys) {
        $a = $audits[$t]
        if ($null -eq $a) { $row += 'MISSING'; continue }
        if ($a.Exposure.State -ne 'ok') { $row += $a.Exposure.State.ToUpperInvariant(); continue }
        $v = Get-ReportValue $a.Exposure $field
        if ($null -eq $v) { $row += '(null / not reported)' } else { $row += (Get-Cell $v) }
    }
    $rows += , $row
}
Write-Grid -Columns $columns -Rows $rows

# Every native arrival, including any the context table has no row for. A
# method name that reached native from somewhere unaccounted for is the single
# most important thing this audit could find, so it is never summarized away.
Write-Host ''
Write-Host '  native arrivals, verbatim (method name -> count):'
$allMethods = New-Object System.Collections.Generic.List[string]
foreach ($t in $present) {
    $arrivals = Get-Prop $audits[$t].Doc 'native_arrivals'
    if ($null -eq $arrivals) { continue }
    foreach ($p in $arrivals.PSObject.Properties) {
        if (-not $allMethods.Contains($p.Name)) { [void]$allMethods.Add($p.Name) }
    }
}
if ($allMethods.Count -eq 0) {
    Write-Host '    (no target recorded a single native arrival)'
}
else {
    $rows = @()
    foreach ($m in ($allMethods | Sort-Object)) {
        $row = @($m)
        foreach ($t in $targetFiles.Keys) {
            $a = $audits[$t]
            if ($null -eq $a) { $row += 'MISSING'; continue }
            $v = Get-Prop (Get-Prop $a.Doc 'native_arrivals') $m
            if ($null -eq $v) { $v = 0 }
            $row += (Get-Cell $v)
        }
        $rows += , $row
    }
    Write-Grid -Columns $columns -Rows $rows
}

# --- 2. navigation coverage ---------------------------------------------------

Write-Section 'QUESTION 2 - NAVIGATION COVERAGE'

# One GLOBAL hook legend, assigned over the sorted union of every hook name
# any target recorded. Per-target legends would make the table unreadable in
# exactly the direction that matters: comparing engines row by row.
#
# The legend also carries each hook's POLICY CAPABILITY, taken from the events
# themselves: a hook that can refuse the navigation and a hook that merely
# watches it are not comparable evidence, and a target with more OBSERVATION
# hooks must not be able to look like it cancelled more.
$hookNames = New-Object System.Collections.Generic.List[string]
$hookPolicyTrue = @{}
$hookPolicyFalse = @{}
$hookPolicyAbsent = @{}
foreach ($t in $present) {
    foreach ($ev in @(Get-Prop $audits[$t].Doc 'events')) {
        $h = [string](Get-Prop $ev 'hook')
        if (-not $h) { continue }
        if (-not $hookNames.Contains($h)) {
            [void]$hookNames.Add($h)
            $hookPolicyTrue[$h] = 0
            $hookPolicyFalse[$h] = 0
            $hookPolicyAbsent[$h] = 0
        }
        if (-not (Test-HasProp $ev 'policy')) { $hookPolicyAbsent[$h]++ }
        elseif ((Get-Prop $ev 'policy') -eq $true) { $hookPolicyTrue[$h]++ }
        else { $hookPolicyFalse[$h]++ }
    }
}
$hookToken = @{}
$i = 1
foreach ($h in ($hookNames | Sort-Object)) {
    $hookToken[$h] = "h$i"
    $i++
}

# Per-event policy classification, used by the native table's P/O/U counts.
function Get-EventPolicyClass {
    param($Event)
    if (-not (Test-HasProp $Event 'policy')) { return 'U' }
    if ((Get-Prop $Event 'policy') -eq $true) { return 'P' }
    return 'O'
}

Write-Host '  TWO TAXONOMIES, RENDERED SEPARATELY. [2a] is keyed by the case the'
Write-Host '  NATIVE hook attributed the navigation to (CaseForUri); [2b] is keyed'
Write-Host '  by the case name the PAGE driver used. They are different namespaces:'
Write-Host '  the page''s redirect-out-of-pweb is recorded natively as'
Write-Host '  redirect-first-leg, and merging them printed "no hook saw the'
Write-Host '  redirect" about a redirect the engine did hook. The probes'' own setup'
Write-Host "  navigations - $hostCase - are suppressed from both"
Write-Host '  and counted only in PHASES OBSERVED.'
Write-Host ''
if ($hookToken.Count -eq 0) {
    Write-Host '  hook legend: (no target recorded a navigation hook)'
}
else {
    Write-Host '  hook legend (policy = the hook can REFUSE the navigation;'
    Write-Host '               observe = it only watches it):'
    foreach ($h in ($hookNames | Sort-Object)) {
        $kind = 'unstated (no probe emitted policy for it)'
        if ($hookPolicyAbsent[$h] -eq 0) {
            if ($hookPolicyFalse[$h] -eq 0) { $kind = 'policy' }
            elseif ($hookPolicyTrue[$h] -eq 0) { $kind = 'observe' }
            else { $kind = "DIVERGENT (policy on $($hookPolicyTrue[$h]) event(s), observe on $($hookPolicyFalse[$h]))" }
        }
        elseif (($hookPolicyTrue[$h] -gt 0) -or ($hookPolicyFalse[$h] -gt 0)) {
            $kind = "partial (policy=$($hookPolicyTrue[$h]), observe=$($hookPolicyFalse[$h]), unstated=$($hookPolicyAbsent[$h]))"
        }
        Write-Host "    $($hookToken[$h]) = $h  [$kind]"
    }
}

# The page taxonomy: the corpus the probes run, plus anything a target
# actually reported or beaconed that the list above does not name.
$pageCases = New-Object System.Collections.Generic.List[string]
foreach ($c in $coverageCases) { [void]$pageCases.Add($c) }
foreach ($t in $present) {
    foreach ($n in $audits[$t].Cases.Keys) {
        if (-not $pageCases.Contains($n)) { [void]$pageCases.Add($n) }
    }
    foreach ($n in $audits[$t].Beacons.Cases) {
        if (-not $pageCases.Contains($n)) { [void]$pageCases.Add($n) }
    }
}

# The native taxonomy: whatever the coverage-phase events were attributed to.
$nativeCases = New-Object System.Collections.Generic.List[string]
foreach ($t in $present) {
    foreach ($ev in @(Get-Prop $audits[$t].Doc 'events')) {
        if ([string](Get-Prop $ev 'phase') -ne 'coverage') { continue }
        $c = [string](Get-Prop $ev 'case')
        if ((-not $c) -or ($c -eq $hostCase)) { continue }
        if (-not $nativeCases.Contains($c)) { [void]$nativeCases.Add($c) }
    }
}

# 2a is keyed by native case name but must still be able to say NOT-RUN, so it
# renders the page corpus first (that is what "should have happened") and then
# any native-only name.
$nativeRowNames = New-Object System.Collections.Generic.List[string]
foreach ($c in $pageCases) { [void]$nativeRowNames.Add($c) }
foreach ($c in $nativeCases) {
    if (-not $nativeRowNames.Contains($c)) { [void]$nativeRowNames.Add($c) }
}

Write-Host ''
Write-Host '  [2a] NATIVE hook coverage (native case attribution x target)'
Write-Host '       cell = <hooks that fired> c=<cancelled> P=<events on policy hooks>'
Write-Host '              O=<events on observe-only hooks> U=<events with no policy field>'
Write-Host '       NOT-RUN  this target never started the case (no enter/ or leave/ beacon)'
Write-Host '       NO-HOOK  the case DID start and no native hook recorded it'
Write-Host '       ~        the target emitted no beacons array, so "did it start" is unknowable'
Write-Host '       [n]      a native-only attribution: no page case ever carried this name'
Write-Host ''
$rows = @()
foreach ($caseName in $nativeRowNames) {
    $label = $caseName
    if (-not $pageCases.Contains($caseName)) { $label = "$caseName [n]" }
    $row = @($label)
    foreach ($t in $targetFiles.Keys) {
        $a = $audits[$t]
        if ($null -eq $a) { $row += 'MISSING'; continue }
        $hooks = New-Object System.Collections.Generic.List[string]
        $cancelled = 0
        $nP = 0; $nO = 0; $nU = 0
        foreach ($ev in @(Get-Prop $a.Doc 'events')) {
            if ([string](Get-Prop $ev 'phase') -ne 'coverage') { continue }
            if ([string](Get-Prop $ev 'case') -ne $caseName) { continue }
            $tok = $hookToken[[string](Get-Prop $ev 'hook')]
            if ($tok -and -not $hooks.Contains($tok)) { [void]$hooks.Add($tok) }
            if ((Get-Prop $ev 'cancelled') -eq $true) { $cancelled++ }
            switch (Get-EventPolicyClass $ev) {
                'P' { $nP++ }
                'O' { $nO++ }
                default { $nU++ }
            }
        }
        if ($hooks.Count -eq 0) {
            # NOT-RUN is decided ONLY from this target's own beacons, and only
            # for a name the page taxonomy knows: a native-only attribution has
            # no beacon to look for and its absence proves nothing.
            if ($pageCases.Contains($caseName)) {
                if (-not $a.Beacons.Present) { $row += 'NO-HOOK ~' }
                elseif (-not $a.Beacons.Cases.Contains($caseName)) { $row += 'NOT-RUN' }
                else { $row += 'NO-HOOK' }
            }
            else { $row += '-' }
            continue
        }
        $cell = "$($hooks -join ',') c=$cancelled P=$nP"
        if ($nO -gt 0) { $cell += " O=$nO" }
        if ($nU -gt 0) { $cell += " U=$nU" }
        $row += $cell
    }
    $rows += , $row
}
Write-Grid -Columns $columns -Rows $rows

Write-Host ''
Write-Host '  [2b] PAGE-observed outcome (page case name x target)'
Write-Host '       cell = flags, all that apply, so no observation outranks another'
Write-Host '       .        the document was still on the trusted origin and nothing else happened'
Write-Host '       !        the document left the trusted origin (href in -Detail)'
Write-Host '       T        the navigation attempt threw in the page'
Write-Host '       M        THIS case set the marker (a javascript: URL executed here).'
Write-Host '                The marker is sticky in the raw report - only scheme-javascript'
Write-Host '                ever sets it and every later case inherits it - so M is printed'
Write-Host '                only where the value CHANGED from the previous case.'
Write-Host '       ?        the case ran and the page reported nothing for it'
Write-Host '       NOT-RUN  no enter/ or leave/ beacon: the case never started here'
Write-Host '       ~        no beacons array, so "did it start" is unknowable'
Write-Host '       trusted origin = exactly pweb://app, or pweb://app followed by / # or ?'
Write-Host '       (a prefix test would call pweb://app.evil/ and pweb://app@evil/ trusted)'
Write-Host ''
$rows = @()
foreach ($caseName in $pageCases) {
    $row = @($caseName)
    foreach ($t in $targetFiles.Keys) {
        $a = $audits[$t]
        if ($null -eq $a) { $row += 'MISSING'; continue }
        if ($a.Coverage.State -eq 'absent') { $row += 'NO-REPORT'; continue }
        if ($a.Coverage.State -eq 'unparsed') { $row += 'UNPARSED'; continue }
        $rec = $null
        if ($a.Cases.Contains($caseName)) { $rec = $a.Cases[$caseName] }
        if ($null -eq $rec) {
            if (-not $a.Beacons.Present) { $row += '? ~' }
            elseif (-not $a.Beacons.Cases.Contains($caseName)) { $row += 'NOT-RUN' }
            else { $row += '?' }
            continue
        }
        $flags = ''
        if ($null -ne $rec.Threw) { $flags += 'T' }
        if ($rec.MarkerChanged -and ($null -ne $rec.Marker)) { $flags += 'M' }
        if (-not (Test-TrustedOrigin $rec.Href)) { $flags += '!' }
        if ($flags -eq '') { $flags = '.' }
        $row += $flags
    }
    $rows += , $row
}
Write-Grid -Columns $columns -Rows $rows

# The page's own last word on where it ended up. Measured, and never rendered
# before: every [2b] cell is relative to it.
Write-Host ''
Write-Host '  final href reported at the end of the coverage phase:'
foreach ($t in $targetFiles.Keys) {
    $a = $audits[$t]
    if ($null -eq $a) { Write-Host "    ${t}: MISSING"; continue }
    $fh = Get-ReportValue $a.Coverage 'finalHref'
    if ($null -eq $fh) { Write-Host "    ${t}: (not reported)"; continue }
    $verdict = if (Test-TrustedOrigin ([string]$fh)) { 'on the trusted origin' } else { 'OFF the trusted origin' }
    Write-Host "    ${t}: $fh   [$verdict]"
}

# --- 2b. user_initiated, with the basis that makes it comparable --------------

Write-Section 'USER ACTIVATION - three different quantities, never merged'
Write-Host '  user_initiated is NOT one measurement across targets. Each target''s'
Write-Host '  own sentence, and the per-event basis it recorded, are printed here'
Write-Host '  so the column below is read with the right meaning attached.'
Write-Host ''
foreach ($t in $targetFiles.Keys) {
    $a = $audits[$t]
    if ($null -eq $a) { Write-Host "  ${t}: MISSING"; continue }
    $sem = Get-Prop $a.Doc 'user_initiated_semantics'
    if ([string]::IsNullOrWhiteSpace([string]$sem)) {
        Write-Host "  ${t}: (the document states no user_initiated_semantics)"
    }
    else {
        Write-Host "  ${t}: $sem"
    }
    $bases = [ordered]@{}
    $noBasis = 0
    foreach ($ev in @(Get-Prop $a.Doc 'events')) {
        if (-not (Test-HasProp $ev 'user_initiated_basis')) { $noBasis++; continue }
        $b = [string](Get-Prop $ev 'user_initiated_basis')
        if ([string]::IsNullOrEmpty($b)) { $b = '(empty string)' }
        if ($bases.Contains($b)) { $bases[$b] = $bases[$b] + 1 } else { $bases[$b] = 1 }
    }
    if (($bases.Count -eq 0) -and ($noBasis -eq 0)) {
        Write-Host '      basis: (no events)'
    }
    else {
        foreach ($b in $bases.Keys) { Write-Host "      basis: $b  x$($bases[$b])" }
        if ($noBasis -gt 0) {
            Write-Host "      basis: MISSING - $noBasis event(s) carry no user_initiated_basis"
        }
    }
}

# A compact per-target digest of the same thing, so the counter table below
# can be read column by column without scrolling back up.
Write-Host ''
$row = @('user_initiated basis')
foreach ($t in $targetFiles.Keys) {
    $a = $audits[$t]
    if ($null -eq $a) { $row += 'MISSING'; continue }
    $kinds = [ordered]@{}
    $noBasis = 0
    foreach ($ev in @(Get-Prop $a.Doc 'events')) {
        if (-not (Test-HasProp $ev 'user_initiated_basis')) { $noBasis++; continue }
        $b = [string](Get-Prop $ev 'user_initiated_basis')
        $kind = $b
        $colon = $b.IndexOf(':')
        if ($colon -gt 0) { $kind = $b.Substring(0, $colon) }
        if ([string]::IsNullOrEmpty($kind)) { $kind = '(empty)' }
        if ($kinds.Contains($kind)) { $kinds[$kind] = $kinds[$kind] + 1 } else { $kinds[$kind] = 1 }
    }
    $parts = @()
    foreach ($k in $kinds.Keys) { $parts += "$k($($kinds[$k]))" }
    if ($noBasis -gt 0) { $parts += "MISSING($noBasis)" }
    if ($parts.Count -eq 0) { $row += '(no events)' } else { $row += ($parts -join '+') }
}
Write-Grid -Columns $columns -Rows @(, $row)

# user_initiated / redirected / cancelled / bootstrap_allowed are per-EVENT
# flags rather than per-case ones, so they are counted rather than folded into
# the tables above. n/a is counted SEPARATELY from false, because a hook that
# was never asked did not answer "no".
Write-Host ''
Write-Host '  coverage-phase event counters (n/a = user_initiated is JSON null:'
Write-Host '  the engine was not asked or the hook cannot answer):'
Write-Host ''
$rows = @()
foreach ($field in @(
        @{ Label = 'coverage events'; Test = { param($ev) $true } },
        @{ Label = '  user_initiated=true'; Test = { param($ev) (Get-UserInitiatedCell $ev) -eq 'true' } },
        @{ Label = '  user_initiated=false'; Test = { param($ev) (Get-UserInitiatedCell $ev) -eq 'false' } },
        @{ Label = '  user_initiated=n/a'; Test = { param($ev) (Get-UserInitiatedCell $ev) -eq 'n/a' } },
        @{ Label = '  user_initiated MISSING'; Test = { param($ev) (Get-UserInitiatedCell $ev) -eq 'MISSING' } },
        @{ Label = '  redirected=true'; Test = { param($ev) (Get-Prop $ev 'redirected') -eq $true } },
        @{ Label = '  cancelled=true'; Test = { param($ev) (Get-Prop $ev 'cancelled') -eq $true } },
        @{ Label = '  bootstrap_allowed=true'; Test = { param($ev) (Get-Prop $ev 'bootstrap_allowed') -eq $true } },
        @{ Label = '  on a policy hook'; Test = { param($ev) (Get-EventPolicyClass $ev) -eq 'P' } },
        @{ Label = '  on an observe-only hook'; Test = { param($ev) (Get-EventPolicyClass $ev) -eq 'O' } },
        @{ Label = '  policy field absent'; Test = { param($ev) (Get-EventPolicyClass $ev) -eq 'U' } })) {
    $row = @($field.Label)
    foreach ($t in $targetFiles.Keys) {
        $a = $audits[$t]
        if ($null -eq $a) { $row += 'MISSING'; continue }
        $n = 0
        foreach ($ev in @(Get-Prop $a.Doc 'events')) {
            if ([string](Get-Prop $ev 'phase') -ne 'coverage') { continue }
            if (& $field.Test $ev) { $n++ }
        }
        $row += "$n"
    }
    $rows += , $row
}
Write-Grid -Columns $columns -Rows $rows

# --- 2c. every phase, including the user-activation controls ------------------
#
# DERIVED FROM THE DOCUMENT, never from a list of phase names written here.
# The probes grew four user-activation phases (a bare script navigation, one
# after a binding promise resolves, one after webview_eval, one after a real
# synthesized click) after the first version of this reader shipped, and a
# summarizer that only knew the four original phases would have rendered them
# as nothing at all. Whatever phases a probe runs, they appear.
#
# The u= column is the second half of audit question 2 - "can the platform
# distinguish user-initiated from script-initiated" - and it is answered by
# comparing the same row across targets, which is why it is a table rather
# than a note.
Write-Section 'PHASES OBSERVED (events / user-initiated / cancelled, per phase)'
Write-Host '  cell = <events> u=<user_initiated=true> na=<null> c=<cancelled=true>'
Write-Host ''
$observedPhases = New-Object System.Collections.Generic.List[string]
foreach ($t in $present) {
    foreach ($ev in @(Get-Prop $audits[$t].Doc 'events')) {
        $p = [string](Get-Prop $ev 'phase')
        if ($p -and -not $observedPhases.Contains($p)) { [void]$observedPhases.Add($p) }
    }
}
if ($observedPhases.Count -eq 0) {
    Write-Host '  (no target recorded a single navigation event)'
}
else {
    $rows = @()
    foreach ($phaseName in $observedPhases) {
        $row = @($phaseName)
        foreach ($t in $targetFiles.Keys) {
            $a = $audits[$t]
            if ($null -eq $a) { $row += 'MISSING'; continue }
            $n = 0
            $u = 0
            $na = 0
            $c = 0
            foreach ($ev in @(Get-Prop $a.Doc 'events')) {
                if ([string](Get-Prop $ev 'phase') -ne $phaseName) { continue }
                $n++
                $ui = Get-UserInitiatedCell $ev
                if ($ui -eq 'true') { $u++ }
                elseif ($ui -ne 'false') { $na++ }
                if ((Get-Prop $ev 'cancelled') -eq $true) { $c++ }
            }
            if ($n -eq 0) { $row += '-' } else { $row += "$n u=$u na=$na c=$c" }
        }
        $rows += , $row
    }
    Write-Grid -Columns $columns -Rows $rows
}

# --- 2d. the per-event fields only some probes can record ---------------------
#
# main_frame is the ONLY per-event frame discriminator WebKit offers - there is
# no separate FrameNavigationStarting there, so "was this the top document" is
# answerable on macOS solely through this field. Rendering it nowhere made the
# macOS column unreadable for the one question its hook shape forces.
$frameFields = @('main_frame', 'nav_type', 'target_frame', 'source')
$anyFrameField = $false
foreach ($t in $present) {
    foreach ($ev in @(Get-Prop $audits[$t].Doc 'events')) {
        foreach ($f in $frameFields) {
            if (Test-HasProp $ev $f) { $anyFrameField = $true; break }
        }
        if ($anyFrameField) { break }
    }
    if ($anyFrameField) { break }
}
Write-Section 'PER-EVENT ENGINE DETAIL (only where the hook exposes it)'
if (-not $anyFrameField) {
    Write-Host '  no target recorded main_frame, nav_type, target_frame or source'
    Write-Host '  (these come from the WKWebView decidePolicyForNavigationAction'
    Write-Host '  arguments; a probe whose hook exposes none of them emits none)'
}
else {
    Write-Host '  main_frame is the ONLY per-event frame discriminator WebKit'
    Write-Host '  offers - there is no separate frame-navigation hook there - so on'
    Write-Host '  a WKWebView target this row is the whole answer to "was this the'
    Write-Host '  top document".'
    Write-Host ''
    Write-Host '  counted over ALL events, not only coverage ones. A blank column'
    Write-Host '  means that probe''s hook exposes nothing of the kind - which is a'
    Write-Host '  measurement about the engine, not a gap in the document.'
    Write-Host ''
    $valueRows = New-Object System.Collections.Generic.List[string]
    foreach ($f in $frameFields) {
        foreach ($t in $present) {
            foreach ($ev in @(Get-Prop $audits[$t].Doc 'events')) {
                if (-not (Test-HasProp $ev $f)) { continue }
                $v = Get-Prop $ev $f
                $key = "${f}=$(Get-Cell $v)"
                if ($null -eq $v) { $key = "${f}=(null)" }
                if (-not $valueRows.Contains($key)) { [void]$valueRows.Add($key) }
            }
        }
    }
    $rows = @()
    foreach ($key in $valueRows) {
        $split = $key.IndexOf('=')
        $fname = $key.Substring(0, $split)
        $fval = $key.Substring($split + 1)
        $row = @($key)
        foreach ($t in $targetFiles.Keys) {
            $a = $audits[$t]
            if ($null -eq $a) { $row += 'MISSING'; continue }
            $n = 0
            $hasField = $false
            foreach ($ev in @(Get-Prop $a.Doc 'events')) {
                if (-not (Test-HasProp $ev $fname)) { continue }
                $hasField = $true
                $v = Get-Prop $ev $fname
                $cell = if ($null -eq $v) { '(null)' } else { (Get-Cell $v) }
                if ($cell -eq $fval) { $n++ }
            }
            if (-not $hasField) { $row += '-' } else { $row += "$n" }
        }
        $rows += , $row
    }
    Write-Grid -Columns $columns -Rows $rows
}

# `detail` is FREE FORM and NEVER PARSED - it is whatever that hook had to say
# about that event - so it is listed, not tabulated. Listed all the same:
# a per-hook remark no reader ever sees is a measurement that was taken and
# thrown away.
Write-Host ''
Write-Host '  per-event `detail`, distinct non-empty strings (free form, never parsed):'
$anyDetail = $false
foreach ($t in $targetFiles.Keys) {
    $a = $audits[$t]
    if ($null -eq $a) { continue }
    $seen = [ordered]@{}
    foreach ($ev in @(Get-Prop $a.Doc 'events')) {
        if (-not (Test-HasProp $ev 'detail')) { continue }
        $d = [string](Get-Prop $ev 'detail')
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        if ($seen.Contains($d)) { $seen[$d] = $seen[$d] + 1 } else { $seen[$d] = 1 }
    }
    if ($seen.Count -eq 0) { continue }
    $anyDetail = $true
    Write-Host "    ${t}:"
    foreach ($d in $seen.Keys) { Write-Host "      x$($seen[$d])  $d" }
}
if (-not $anyDetail) {
    Write-Host '    (no target attached a non-empty detail to any event)'
}

# --- 3. active subresources ---------------------------------------------------

Write-Section 'QUESTION 3 - ACTIVE SUBRESOURCES (probe row x target)'
Write-Host '  Two independent runs of the same page: the first carries the'
Write-Host '  candidate CSP as a RESPONSE HEADER only; the second adds a'
Write-Host '  deliberately WEAKER <meta> policy to the same document. A row'
Write-Host '  that changes between the two tables is a bundle <meta> weakening'
Write-Host '  the native policy - which is the thing being measured.'
Write-Host '  A cell marked * was normalized from a JSON boolean (true->ran,'
Write-Host '  false->blocked); every normalization is named under the table,'
Write-Host '  because a row that is a string on one target and a boolean on'
Write-Host '  another is a divergence between INSTRUMENTS, not between engines.'

function Write-CspTable {
    param([string]$Which)
    $observed = New-Object System.Collections.Generic.List[string]
    foreach ($r in $cspRows) { [void]$observed.Add($r) }
    foreach ($t in $present) {
        foreach ($n in @(Get-ReportRowNames $audits[$t].$Which)) {
            if (-not $observed.Contains($n)) { [void]$observed.Add($n) }
        }
    }
    $out = @()
    $divergences = New-Object System.Collections.Generic.List[string]
    foreach ($r in $observed) {
        $row = @($r)
        $shapes = [ordered]@{}
        foreach ($t in $targetFiles.Keys) {
            $a = $audits[$t]
            if ($null -eq $a) { $row += 'MISSING'; continue }
            $rep = $a.$Which
            if ($rep.State -eq 'absent') { $row += 'NO-REPORT'; continue }
            if ($rep.State -eq 'unparsed') { $row += 'UNPARSED'; continue }
            $hit = Get-ReportRow $rep $r
            if ($null -eq $hit) { $row += '-'; continue }
            $v = $hit.Value
            if ($v -is [bool]) {
                # NORMALIZED, and said so: 'true' and 'ran' are the same
                # measurement rendered by two instruments, and printing
                # `ran | ran | true | true` invites a reader to conclude the
                # last two engines did something different.
                $shapes['boolean'] = $true
                $row += $(if ($v) { 'ran*' } else { 'blocked*' })
            }
            else {
                $shapes['string'] = $true
                $row += (Get-Cell $v)
            }
        }
        if ($shapes.Count -gt 1) {
            [void]$divergences.Add("    row '$r': reported as a JSON boolean by one target and a JSON string by another")
        }
        $out += , $row
    }
    $row = @('violations reported')
    foreach ($t in $targetFiles.Keys) {
        $a = $audits[$t]
        if ($null -eq $a) { $row += 'MISSING'; continue }
        $rep = $a.$Which
        if ($rep.State -ne 'ok') { $row += $rep.State.ToUpperInvariant(); continue }
        $row += "$(@(Get-ReportList $rep 'violations').Count)"
    }
    $out += , $row
    Write-Grid -Columns $columns -Rows $out
    if ($divergences.Count -gt 0) {
        Write-Host ''
        Write-Host '  INSTRUMENT DIVERGENCE (normalized above, not a finding about the engine):'
        foreach ($d in $divergences) { Write-Host $d }
    }
}

# THE VIOLATIONS THEMSELVES. Until now the reader COUNTED them and stopped,
# which threw away the entire substance of audit question 3: "9 violations"
# says nothing, while `frame-src blocked pweb` and `base-uri blocked
# https://example.invalid/` are the measurement. Each distinct
# directive/blocked pair gets a row and each target a count, so a directive
# that fires on one engine and not another is visible at a glance.
function Write-CspViolations {
    param([string]$Which)
    $pairs = New-Object System.Collections.Generic.List[string]
    $counts = @{}
    foreach ($t in $present) {
        $rep = $audits[$t].$Which
        foreach ($v in @(Get-ReportList $rep 'violations')) {
            $d = [string](Get-Prop $v 'directive')
            $b = Get-Prop $v 'blocked'
            # `blockedURI` is tolerated as an alias so a probe that renames the
            # field does not silently empty this table.
            if ($null -eq $b) { $b = Get-Prop $v 'blockedURI' }
            if ($null -eq $b) { $b = '(not reported)' }
            $key = "$d | $b"
            if (-not $pairs.Contains($key)) { [void]$pairs.Add($key) }
            $ck = "$t`u{1}$key"
            if ($counts.ContainsKey($ck)) { $counts[$ck] = $counts[$ck] + 1 }
            else { $counts[$ck] = 1 }
        }
    }
    if ($pairs.Count -eq 0) {
        Write-Host '    (no target reported a single securitypolicyviolation)'
        return
    }
    $out = @()
    foreach ($key in $pairs) {
        $row = @($key)
        foreach ($t in $targetFiles.Keys) {
            $a = $audits[$t]
            if ($null -eq $a) { $row += 'MISSING'; continue }
            $rep = $a.$Which
            if ($rep.State -ne 'ok') { $row += $rep.State.ToUpperInvariant(); continue }
            $ck = "$t`u{1}$key"
            if ($counts.ContainsKey($ck)) { $row += "$($counts[$ck])" } else { $row += '.' }
        }
        $out += , $row
    }
    Write-Grid -Columns (@('directive | blockedURI') + @($targetFiles.Keys)) -Rows $out
}

Write-Host ''
Write-Host '  [3a] CSP delivered as a RESPONSE HEADER on pweb://app'
Write-Host ''
Write-CspTable -Which 'Csp'
Write-Host ''
Write-Host '  [3a-v] the violations that produced those rows, verbatim (count per target):'
Write-Host ''
Write-CspViolations -Which 'Csp'
Write-Host ''
Write-Host '  [3b] the same header PLUS a weaker bundle <meta> CSP'
Write-Host ''
Write-CspTable -Which 'CspMeta'
Write-Host ''
Write-Host '  [3b-v] the violations that produced those rows, verbatim (count per target):'
Write-Host ''
Write-CspViolations -Which 'CspMeta'

# --- 4. per-target detail -----------------------------------------------------

if ($Detail) {
    $detailTargets = if ($RequireTarget) { @($RequireTarget) } else { $present }
    foreach ($t in $detailTargets) {
        $a = $audits[$t]
        Write-Section "DETAIL - $t"
        if ($null -eq $a) {
            Write-Host "  $($problems[$t])"
            continue
        }
        Write-Host "  file: $($a.File)"
        Write-Host "  engine: $(Get-Prop $a.Doc 'engine') $(Get-Prop $a.Doc 'engine_version')"
        Write-Host "  initial source before navigate: '$(Get-Prop $a.Doc 'initial_source_before_navigate')'"
        Write-Host "  csp headers emitted: $(Get-Prop $a.Doc 'csp_headers_emitted')"
        Write-Host "  download hook available: $(Get-Cell (Get-Prop $a.Doc 'download_hook_available'))"
        Write-Host "  user_initiated semantics: $(Get-Prop $a.Doc 'user_initiated_semantics')"

        Write-Host ''
        Write-Host '  native arrivals:'
        $arrivals = Get-Prop $a.Doc 'native_arrivals'
        $props = @()
        if ($null -ne $arrivals) { $props = @($arrivals.PSObject.Properties) }
        if ($props.Count -eq 0) {
            Write-Host '    (none - nothing reached the privileged binding)'
        }
        else {
            foreach ($p in ($props | Sort-Object Name)) {
                Write-Host ("    {0,-40} {1}" -f $p.Name, $p.Value)
            }
        }

        Write-Host ''
        Write-Host '  exposure records, field by field:'
        $recs = @(Get-ReportList $a.Exposure 'records')
        if ($recs.Count -eq 0) {
            Write-Host '    (none)'
        }
        else {
            foreach ($rec in $recs) {
                Write-Host ("    ctx={0} shim={1} webview={2} raw={3} origin={4} shimThrew={5} rawThrew={6}" -f `
                    (Get-Cell (Get-Prop $rec 'ctx')), (Get-Cell (Get-Prop $rec 'shim')),
                    (Get-Cell (Get-Prop $rec 'webview')), (Get-Cell (Get-Prop $rec 'raw')),
                    (Get-Cell (Get-Prop $rec 'origin')),
                    $(if ($null -eq (Get-Prop $rec 'shimThrew')) { 'null' } else { Get-Prop $rec 'shimThrew' }),
                    $(if ($null -eq (Get-Prop $rec 'rawThrew')) { 'null' } else { Get-Prop $rec 'rawThrew' }))
            }
        }

        Write-Host ''
        Write-Host '  navigation events (one line each, in the order recorded;'
        Write-Host '  user=n/a means the field is present and null):'
        $events = @(Get-Prop $a.Doc 'events')
        if ($events.Count -eq 0) {
            Write-Host '    (none)'
        }
        else {
            foreach ($ev in $events) {
                $line = ("    phase={0} case={1} hook={2} user={3} basis={4} policy={5} redirected={6} cancelled={7} bootstrap_allowed={8}" -f `
                        (Get-Cell (Get-Prop $ev 'phase')), (Get-Cell (Get-Prop $ev 'case')),
                    (Get-Cell (Get-Prop $ev 'hook')),
                    (Get-UserInitiatedCell $ev),
                    $(if (Test-HasProp $ev 'user_initiated_basis') { Get-Cell (Get-Prop $ev 'user_initiated_basis') } else { 'MISSING' }),
                    $(if (Test-HasProp $ev 'policy') { Get-Cell (Get-Prop $ev 'policy') } else { 'MISSING' }),
                    (Get-Cell (Get-Prop $ev 'redirected')),
                    (Get-Cell (Get-Prop $ev 'cancelled')),
                    (Get-Cell (Get-Prop $ev 'bootstrap_allowed')))
                foreach ($f in $frameFields) {
                    if (Test-HasProp $ev $f) { $line += " $f=$(Get-Cell (Get-Prop $ev $f))" }
                }
                if (Test-HasProp $ev 'detail') {
                    $d = [string](Get-Prop $ev 'detail')
                    if (-not [string]::IsNullOrEmpty($d)) { $line += " detail='$d'" }
                }
                $line += " uri=$(Get-Cell (Get-Prop $ev 'uri'))"
                Write-Host $line
            }
        }

        Write-Host ''
        Write-Host '  coverage cases as the page reported them, with the marker'
        Write-Host '  interpreted in order (marker-set = it CHANGED on this case):'
        if ($a.Cases.Count -eq 0) {
            Write-Host '    (the page reported no case)'
        }
        else {
            foreach ($name in $a.Cases.Keys) {
                $rec = $a.Cases[$name]
                Write-Host ("    {0,-28} threw={1} marker={2} marker-set={3} trusted-origin={4} href={5}" -f `
                        $rec.Name,
                    $(if ($null -eq $rec.Threw) { 'null' } else { $rec.Threw }),
                    $(if ($null -eq $rec.Marker) { 'null' } else { $rec.Marker }),
                    $($rec.MarkerChanged -and ($null -ne $rec.Marker)),
                    (Test-TrustedOrigin $rec.Href),
                    $rec.Href)
            }
        }

        Write-Host ''
        Write-Host '  beacons, verbatim (the resource-handler record of which cases'
        Write-Host '  actually started; EITHER enter/ or leave/ is proof):'
        if (-not $a.Beacons.Present) {
            Write-Host '    (the document carries no beacons field)'
        }
        elseif ($a.Beacons.Count -eq 0) {
            Write-Host '    (present and empty - no case ever started)'
        }
        else {
            foreach ($b in $a.Beacons.Raw) { Write-Host "    $b" }
            $never = @($pageCases | Where-Object { -not $a.Beacons.Cases.Contains($_) })
            if ($never.Count -gt 0) {
                Write-Host "    NEVER STARTED HERE: $($never -join ', ')"
            }
        }

        Write-Host ''
        Write-Host '  page reports, VERBATIM (the page said this; nothing here'
        Write-Host '  is the harness''s interpretation of it):'
        foreach ($pair in @(
                @{ Label = 'exposure_report'; Field = 'exposure_report' },
                @{ Label = 'coverage_report'; Field = 'coverage_report' },
                @{ Label = 'csp_report'; Field = 'csp_report' },
                @{ Label = 'csp_meta_report'; Field = 'csp_meta_report' })) {
            $raw = [string](Get-Prop $a.Doc $pair.Field)
            if ([string]::IsNullOrWhiteSpace($raw)) {
                Write-Host "    $($pair.Label): NO-REPORT (the page never reported)"
            }
            else {
                Write-Host "    $($pair.Label): $raw"
            }
        }

        $notes = @(Get-Prop $a.Doc 'notes')
        Write-Host ''
        Write-Host '  notes:'
        if ($notes.Count -eq 0) {
            Write-Host '    (none)'
        }
        else {
            foreach ($n in $notes) { Write-Host "    $n" }
        }
    }
}

# --- verdict ------------------------------------------------------------------

Write-Host ''
foreach ($t in $targetFiles.Keys) {
    if ($null -eq $audits[$t]) {
        Write-Host "[CAP-8B] $t : $($problems[$t])"
    }
    else {
        Write-Host "[CAP-8B] $t : measured ($($audits[$t].File))"
    }
}

if ($RequireTarget) {
    if ($null -eq $audits[$RequireTarget]) {
        Write-Host ''
        Write-Host "[CAP-8B] REQUIRED TARGET UNUSABLE: $RequireTarget -- $($problems[$RequireTarget])"
        Write-Host '[CAP-8B] this is a failure OF THE INSTRUMENT, not a measurement'
        exit 1
    }
    Write-Host ''
    Write-Host "[CAP-8B] required target $RequireTarget carries a valid schema-1 audit document"
}
Write-Host '[CAP-8B] summarize_audit: measurement rendered (this script never gates)'
exit 0
