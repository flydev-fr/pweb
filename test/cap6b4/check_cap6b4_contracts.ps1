# CAP-6b4 contract cross-checks (the house 1587-cross-check idiom,
# extended to the one-product/three-modes integration): every string
# and every ORDER that two files must share is proven shared here, so a
# rename or a reordering on either side breaks THIS gate instead of
# silently voiding a runtime gate - or, worse, mislabelling a user's
# machine.
#
#   (a) THE PROFILE MARKER is single-source: the HKCU key path, the
#       value name and the ratified profile-name set are authored once
#       in tools/setup/pwebappsetup.issi, each profile .iss declares
#       exactly one PWEB_PROFILE from that set (case-sensitive, no
#       duplicates), the include validates it at PREPROCESS time with
#       no default, and every consumer script carries the same literals
#   (b) THE SETUP BASENAMES are single-source and none of them is
#       'setup': each .iss authors PWEB_SETUP_BASENAME, the shared
#       include requires it with no default, no build script passes a
#       /F override for a shipped artifact, and no committed file
#       references a dist/windows artifact named setup.exe
#   (c) THE RUNTIME SUBDIR is single-source: PWEB_RUNTIME_SUBDIR is
#       authored once and no other directive line in any setup manifest
#       spells the path out - the tree the fixed profile INSTALLS and
#       the tree the Evergreen profiles RECLAIM must be one directory
#   (d) THE FIXED PROFILE'S [Files] ORDER: the shared release triple is
#       included AFTER the verdict-gate entry. This is the measured fix
#       for matrix row F3 - with the triple before the gate, a failed
#       normal -> fixed switch leaves a fixed-mode binary behind with
#       no runtime tree
#   (e) NO EVERGREEN UNINSTALL PATH anywhere: nothing this repository
#       ships may uninstall, repair or remove the machine's shared
#       WebView2 Evergreen runtime. It is shared machine state PWeb
#       does not own
#   (f) NO USER-DATA DELETION anywhere: the WebView2 user-data folder
#       (%APPDATA%\releaseapp.exe) is SHARED across profiles and
#       PRESERVED by uninstall. No [UninstallDelete], no [InstallDelete]
#       and no gate script may target it
#   (g) PRIOR RUNTIME GATES are AGGREGATED from repository evidence,
#       never re-performed and never upgraded. CAP-6b4 integrates three
#       shards whose external human/VM gates carry DIFFERENT verdicts,
#       and the one thing it must never do is let integration success
#       read as "all tested". This contract reads the append-only
#       ledger, reports the three verdicts as DISTINCT, and STOPS if any
#       record is missing rather than assuming closure
#
# Usage: pwsh -File test/cap6b4/check_cap6b4_contracts.ps1

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

function Get-Text([string]$Rel) {
    $f = Join-Path $RepoRoot $Rel
    if (-not (Test-Path -LiteralPath $f)) { throw "contract file missing: $Rel" }
    Get-Content -LiteralPath $f -Raw
}

# the setup manifests and their shared includes: the whole authoring
# surface these contracts are about
$SetupSources = @(
    'tools/setup/pwebappsetup.issi',
    'tools/setup/pwebapppayload.issi',
    'tools/setup/pwebprovgate.issi',
    'tools/setup/normal.iss',
    'tools/setup/offline.iss',
    'tools/setup/fixed.iss'
)
foreach ($rel in $SetupSources) { [void](Get-Text $rel) }

# A setup manifest is line-oriented and ';'-commented: a contract about
# what the setup DOES must read directives only, or a comment explaining
# an invariant would be mistaken for a violation of it. Inno also
# continues a long entry with a trailing backslash, so the continuations
# are folded back into one logical line first - otherwise an entry's
# Flags: would look absent merely because it sits on the next physical
# line.
function Get-DirectiveLines([string]$Rel) {
    $out = @()
    $pending = ''
    foreach ($raw in ((Get-Text $Rel) -split "`r?`n")) {
        if ($raw.Trim() -eq '') { continue }
        # ';' comments everywhere, '//' comments inside [Code] - both are
        # commentary, and a comment explaining an invariant must never be
        # mistaken for a directive violating it
        if ($raw.TrimStart().StartsWith(';')) { continue }
        if ($raw.TrimStart().StartsWith('//')) { continue }
        $line = $raw
        if ($line.TrimEnd().EndsWith('\')) {
            $pending += ($line.TrimEnd().TrimEnd('\')) + ' '
            continue
        }
        $out += ($pending + $line)
        $pending = ''
    }
    if ($pending -ne '') { $out += $pending }
    # POSITIVE CONTROL. Every contract below that sweeps directive lines
    # looking for ZERO hits would report PASS having examined nothing if
    # this parser ever returned an empty set (a comment-syntax change, a
    # continuation bug, an encoding surprise). Every manifest this
    # repository ships has directives, so an empty result is a broken
    # parser, never a clean file.
    if ($out.Count -eq 0) {
        throw ("the directive parser produced NO lines for $Rel - a sweep over " +
            'an empty set would report PASS having examined nothing')
    }
    $out
}

$identity = Get-Text 'tools/setup/pwebappsetup.issi'

# --- (a) the profile marker, single-source -----------------------------------
$markerDefines = @{}
foreach ($name in 'PWEB_MARKER_PARENT', 'PWEB_MARKER_KEY', 'PWEB_MARKER_VALUE',
    'PWEB_PROFILE_SET') {
    $m = [regex]::Match($identity, "(?m)^#define\s+$name\s+`"([^`"]+)`"\s*$")
    if (-not $m.Success) {
        throw "pwebappsetup.issi does not author the $name define"
    }
    $markerDefines[$name] = $m.Groups[1].Value
}
$MarkerKey = $markerDefines['PWEB_MARKER_KEY']
$MarkerValue = $markerDefines['PWEB_MARKER_VALUE']
if ($MarkerKey -cne 'Software\PWeb\PWebRelease') {
    throw "the ratified marker key is Software\PWeb\PWebRelease, the include says '$MarkerKey'"
}
if ($MarkerValue -cne 'Profile') {
    throw "the ratified marker value name is Profile, the include says '$MarkerValue'"
}
if (-not $MarkerKey.StartsWith($markerDefines['PWEB_MARKER_PARENT'] + '\',
        [StringComparison]::Ordinal)) {
    throw ("the marker key '$MarkerKey' is not under its own declared parent " +
        "'$($markerDefines['PWEB_MARKER_PARENT'])' - uninsdeletekeyifempty would " +
        'then leave an orphan key behind')
}
# the ratified set, parsed from the include's own '|a|b|c|' literal
$ProfileNames = @($markerDefines['PWEB_PROFILE_SET'] -split '\|' |
    Where-Object { $_ -ne '' })
$expectedNames = @('normal', 'offline', 'fixed-runtime')
if (($ProfileNames -join ',') -cne ($expectedNames -join ',')) {
    throw ("the ratified profile-name set is [$($expectedNames -join ', ')], the " +
        "include declares [$($ProfileNames -join ', ')]")
}
# the include must REQUIRE the define (no default) and validate it at
# preprocess time against that very set
if ($identity -notmatch '(?m)^\s*#ifndef\s+PWEB_PROFILE\s*$') {
    throw 'pwebappsetup.issi does not guard PWEB_PROFILE with #ifndef'
}
if ($identity -match '(?m)^\s*#define\s+PWEB_PROFILE\s+') {
    throw ('pwebappsetup.issi DEFAULTS PWEB_PROFILE - a default silently stamps ' +
        "a wrong mode onto a user's machine")
}
if ($identity -notmatch '(?ms)#ifndef\s+PWEB_PROFILE\s*\r?\n\s*#error') {
    throw 'pwebappsetup.issi does not #error on an absent PWEB_PROFILE'
}
if ($identity -notmatch '(?m)^\s*#if\s+Pos\("\|"\s*\+\s*PWEB_PROFILE\s*\+\s*"\|",\s*PWEB_PROFILE_SET\)\s*==\s*0\s*$') {
    throw ('pwebappsetup.issi does not validate PWEB_PROFILE against ' +
        'PWEB_PROFILE_SET with the case-sensitive Pos() form')
}
# the marker is written by Inno's own [Registry] phase - never by
# [Code], never by a helper: that is what makes it the commit point
if ($identity -notmatch '(?m)^\[Registry\]\s*$') {
    throw 'pwebappsetup.issi authors no [Registry] section - the marker is not written'
}
$registryLines = @(Get-DirectiveLines 'tools/setup/pwebappsetup.issi' |
    Where-Object { $_ -match 'ValueName:\s*"' })
if ($registryLines.Count -ne 1) {
    throw ("pwebappsetup.issi writes $($registryLines.Count) registry VALUES; " +
        'the marker is exactly one')
}
foreach ($needed in "ValueName: `"{#PWEB_MARKER_VALUE}`"",
                    "ValueData: `"{#PWEB_PROFILE}`"",
                    'uninsdeletevalue') {
    if ($registryLines[0] -cnotmatch [regex]::Escape($needed)) {
        throw "the marker registry entry lost '$needed': $($registryLines[0])"
    }
}
if ($identity -notmatch 'uninsdeletekeyifempty') {
    throw 'the marker key is not removed by uninstall (uninsdeletekeyifempty absent)'
}
# each profile declares exactly one name, from the set, case-exact
$ProfileByIss = [ordered]@{
    'tools/setup/normal.iss'  = 'normal'
    'tools/setup/offline.iss' = 'offline'
    'tools/setup/fixed.iss'   = 'fixed-runtime'
}
$seen = @{}
foreach ($rel in $ProfileByIss.Keys) {
    $text = Get-Text $rel
    $ms = @([regex]::Matches($text, '(?m)^#define\s+PWEB_PROFILE\s+"([^"]+)"\s*$'))
    if ($ms.Count -ne 1) {
        throw "$rel authors $($ms.Count) PWEB_PROFILE defines; exactly one is required"
    }
    $name = $ms[0].Groups[1].Value
    if ($name -cne $ProfileByIss[$rel]) {
        throw "$rel declares profile '$name'; the ratified name is '$($ProfileByIss[$rel])'"
    }
    if ($ProfileNames -cnotcontains $name) {
        throw "$rel declares '$name', which is not in the validated set"
    }
    if ($seen.ContainsKey($name)) {
        throw "profile name '$name' is declared by two manifests - modes must be distinct"
    }
    $seen[$name] = $rel
}
# and the marker's consumers carry the same key/value literals, so a
# rename here breaks this gate rather than a runtime assertion
$markerConsumers = @(
    'test/cap6b4/run_profile_matrix.ps1'
)
foreach ($rel in $markerConsumers) {
    $text = Get-Text $rel
    foreach ($lit in $MarkerKey, $MarkerValue) {
        if (-not $text.Contains($lit)) {
            throw "$rel does not carry the marker literal '$lit'"
        }
    }
    foreach ($name in $ProfileNames) {
        if (-not $text.Contains($name)) {
            throw "$rel does not carry the ratified profile name '$name'"
        }
    }
}
Write-Host ("CAP-6b4 contract (a) PASS (marker HKCU\$MarkerKey value '$MarkerValue' " +
    "authored once, required+validated at preprocess time, " +
    "$($ProfileNames.Count) distinct profile names, " +
    "$($markerConsumers.Count) consumer(s) in step)")

# --- (b) the setup basenames, single-source, none of them 'setup' ------------
if ($identity -notmatch '(?m)^\s*#ifndef\s+PWEB_SETUP_BASENAME\s*$') {
    throw 'pwebappsetup.issi does not guard PWEB_SETUP_BASENAME with #ifndef'
}
if ($identity -match '(?m)^\s*#define\s+PWEB_SETUP_BASENAME\s+') {
    throw 'pwebappsetup.issi DEFAULTS PWEB_SETUP_BASENAME - there must be no default'
}
if ($identity -notmatch '(?m)^OutputBaseFilename=\{#PWEB_SETUP_BASENAME\}\s*$') {
    throw 'pwebappsetup.issi does not wire OutputBaseFilename to PWEB_SETUP_BASENAME'
}
$ExpectedBasenames = [ordered]@{
    'tools/setup/normal.iss'  = 'PWebRelease-Normal-Setup'
    'tools/setup/offline.iss' = 'PWebRelease-Offline-Setup'
    'tools/setup/fixed.iss'   = 'PWebRelease-FixedRuntime-Setup'
}
$Basenames = [ordered]@{}
foreach ($rel in $ExpectedBasenames.Keys) {
    $ms = @([regex]::Matches((Get-Text $rel),
        '(?m)^#define\s+PWEB_SETUP_BASENAME\s+"([^"]+)"\s*$'))
    if ($ms.Count -ne 1) {
        throw "$rel authors $($ms.Count) PWEB_SETUP_BASENAME defines; exactly one is required"
    }
    $base = $ms[0].Groups[1].Value
    if ($base -cne $ExpectedBasenames[$rel]) {
        throw "$rel names its artifact '$base'; the ratified basename is '$($ExpectedBasenames[$rel])'"
    }
    if ($base -ieq 'setup') {
        throw "$rel names its artifact 'setup' - the appcompat DLL-planting shim"
    }
    $Basenames[$rel] = $base
}
if (@($Basenames.Values | Sort-Object -Unique).Count -ne $Basenames.Count) {
    throw 'two profiles share one setup basename - one would overwrite the other'
}
# no build script may re-introduce the shimmed name through /F, and every
# consumer must follow the manifest-authored basename
$BasenameConsumers = [ordered]@{
    'PWebRelease-Normal-Setup'      = @(
        'test/cap6b1/build_normal_setup.ps1',
        'test/cap6b1/run_normal_setup_gates.ps1',
        'test/cap6b1/run_clean_machine_gate.ps1'
    )
    'PWebRelease-Offline-Setup'     = @(
        'test/cap6b2/build_offline_setup.ps1',
        'test/cap6b2/run_offline_setup_gates.ps1',
        'test/cap6b2/run_offline_clean_machine_gate.ps1'
    )
    'PWebRelease-FixedRuntime-Setup' = @(
        'test/cap6b3/build_fixed_setup.ps1',
        'test/cap6b3/run_fixed_setup_gates.ps1',
        'test/cap6b3/run_fixed_clean_machine_gate.ps1'
    )
}
foreach ($base in $BasenameConsumers.Keys) {
    foreach ($rel in $BasenameConsumers[$base]) {
        if (-not (Get-Text $rel).Contains($base)) {
            throw "$rel does not carry the manifest-authored basename '$base'"
        }
    }
}
# the /F ban: the ONLY permitted /F is the TEST-ONLY abort probe, which
# is a build/ artifact and is never shipped
$FScripts = @(
    'test/cap6b1/build_normal_setup.ps1',
    'test/cap6b2/build_offline_setup.ps1',
    'test/cap6b3/build_fixed_setup.ps1',
    'test/cap6b4/build_switch_probes.ps1'
)
# ANY /F argument, quoted or bare: `& $Iscc /Fsetup ...` is valid
# PowerShell, so a quote-anchored pattern would not see it at all. The
# scan runs over the script's real TOKENS rather than its text, so a
# comment explaining the ban ("never passed with /F: ...") cannot be
# mistaken for the ban being broken.
function Get-CodeTokens([string]$Rel) {
    $toks = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $RepoRoot $Rel), [ref]$toks, [ref]$null)
    if (($null -eq $toks) -or ($toks.Count -eq 0)) {
        throw "the PowerShell tokenizer produced no tokens for $Rel - a sweep over an empty set proves nothing"
    }
    @($toks | Where-Object { $_.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment } |
        ForEach-Object { $_.Text })
}
foreach ($rel in $FScripts) {
    foreach ($tok in (Get-CodeTokens $rel)) {
        $bare = $tok.Trim("'", '"')
        if ($bare -cmatch '^/F(\S+)$') {
            if ($Matches[1] -cne 'abortprobe') {
                throw ("$rel passes an ISCC output override '$bare' - the manifest " +
                    'must be the single source of a shipped artifact name (only the ' +
                    "TEST-ONLY '/Fabortprobe' is permitted)")
            }
        }
    }
}
# and no committed file may point at a shipped artifact called setup.exe
$shimHits = @(Get-ChildItem -Path (Join-Path $RepoRoot 'test'),
        (Join-Path $RepoRoot 'tools'), (Join-Path $RepoRoot '.github') `
        -Recurse -File -Include '*.ps1', '*.yml', '*.iss', '*.issi' |
    Select-String -Pattern 'dist[/\\]windows[/\\][A-Za-z0-9-]+[/\\]setup\.exe' `
        -CaseSensitive:$false)
if ($shimHits) {
    $shimHits | ForEach-Object {
        Write-Host "SHIMMED ARTIFACT NAME: $($_.Path):$($_.LineNumber): $($_.Line.Trim())"
    }
    throw 'a committed file still references a shipped artifact named setup.exe'
}
Write-Host ("CAP-6b4 contract (b) PASS ($($Basenames.Count) distinct manifest-authored " +
    'basenames, no /F override of a shipped artifact, no setup.exe anywhere)')

# --- (c) the runtime subdir, single-source -----------------------------------
$m = [regex]::Match($identity, '(?m)^#define\s+PWEB_RUNTIME_SUBDIR\s+"([^"]+)"\s*$')
if (-not $m.Success) {
    throw 'pwebappsetup.issi does not author the PWEB_RUNTIME_SUBDIR define'
}
$RuntimeSubdir = $m.Groups[1].Value
if ($RuntimeSubdir -cne 'runtime\webview2') {
    throw "the ratified runtime subdir is runtime\webview2, the include says '$RuntimeSubdir'"
}
# the fixed profile INSTALLS into it and the Evergreen profiles RECLAIM
# it - both through the define, never through a second literal
$fixedIss = Get-Text 'tools/setup/fixed.iss'
if ($fixedIss -notmatch [regex]::Escape('DestDir: "{app}\{#PWEB_RUNTIME_SUBDIR}"')) {
    throw 'fixed.iss does not deploy the runtime tree into {app}\{#PWEB_RUNTIME_SUBDIR}'
}
$mp = [regex]::Match($identity, '(?m)^#define\s+PWEB_RUNTIME_PARENT\s+"([^"]+)"\s*$')
if (-not $mp.Success) {
    throw 'pwebappsetup.issi does not author the PWEB_RUNTIME_PARENT define'
}
$RuntimeParent = $mp.Groups[1].Value
# the parent must really BE the subdir's parent, or the dirifempty
# reclaim would target an unrelated directory
if (-not $RuntimeSubdir.StartsWith($RuntimeParent + '\', [StringComparison]::Ordinal)) {
    throw ("the runtime subdir '$RuntimeSubdir' does not live under its own " +
        "declared parent '$RuntimeParent' - the dirifempty reclaim would target " +
        'a directory this product never created')
}
$provIssi = Get-Text 'tools/setup/pwebprovgate.issi'
if ($provIssi -notmatch '(?m)^\[InstallDelete\]\s*$') {
    throw ('pwebprovgate.issi authors no [InstallDelete] section - installing an ' +
        'Evergreen profile over a fixed one would orphan the ~690 MB runtime tree')
}
$delLines = @(Get-DirectiveLines 'tools/setup/pwebprovgate.issi' |
    Where-Object { $_ -match '^\s*Type:\s*' })
# exactly two, in order: the leaf tree, then the intermediate directory
# that Inno would otherwise leave behind forever (the Evergreen profiles
# never recorded it, so no uninstall of theirs can remove it)
if ($delLines.Count -ne 2) {
    throw ("pwebprovgate.issi declares $($delLines.Count) [InstallDelete] entries; " +
        'exactly two - the runtime subdir and its now-empty parent - are ratified')
}
if ($delLines[0] -cnotmatch [regex]::Escape('Type: filesandordirs; Name: "{app}\{#PWEB_RUNTIME_SUBDIR}"')) {
    throw "the first [InstallDelete] entry is not the ratified tree reclaim: $($delLines[0])"
}
if ($delLines[1] -cnotmatch [regex]::Escape('Type: dirifempty; Name: "{app}\{#PWEB_RUNTIME_PARENT}"')) {
    throw ("the second [InstallDelete] entry is not the ratified empty-parent " +
        "reclaim: $($delLines[1])")
}
# ORDER: dirifempty can only succeed once the leaf is gone, and Inno
# processes [InstallDelete] entries in the order they are written
if ($delLines[0] -match 'dirifempty') {
    throw 'the [InstallDelete] parent reclaim precedes the leaf reclaim - it can never find the parent empty'
}
# OWNERSHIP: {app} is user-redirectable, so an unconditional recursive
# delete could destroy a runtime\webview2 this product never installed
foreach ($d in $delLines) {
    if ($d -cnotmatch 'Check:\s*PWebOwnsInstallDir') {
        throw ("an [InstallDelete] entry runs UNCONDITIONALLY: $d - {app} is " +
            'user-redirectable, so the reclaim must be gated on this being an ' +
            'over-install of our own product')
    }
}
if ($provIssi -notmatch '(?m)^function\s+PWebOwnsInstallDir\s*:\s*Boolean;') {
    throw 'pwebprovgate.issi does not implement the PWebOwnsInstallDir ownership check'
}
# no second spelling of the path in any manifest DIRECTIVE (comments
# that explain the invariant are exempt by construction)
foreach ($rel in $SetupSources) {
    foreach ($line in (Get-DirectiveLines $rel)) {
        if ($line -match '(?i)runtime[\\/]webview2') {
            if ($line -notmatch '(?m)^#define\s+PWEB_RUNTIME_SUBDIR\s') {
                throw ("$rel spells the runtime subdir out instead of using " +
                    "PWEB_RUNTIME_SUBDIR: $($line.Trim())")
            }
        }
    }
}
# and the gate that MEASURES the reclaim must key on the same literal,
# or the single-source proof would not cover the only script that
# observes it on a real machine
$subdirConsumers = @('test/cap6b4/run_profile_matrix.ps1')
foreach ($rel in $subdirConsumers) {
    if (-not (Get-Text $rel).Contains($RuntimeSubdir)) {
        throw ("$rel does not carry the runtime-subdir literal '$RuntimeSubdir' - " +
            'the gate that measures the reclaim would drift from the manifests')
    }
    if (-not (Get-Text $rel).Contains($RuntimeParent)) {
        throw "$rel does not carry the runtime-parent literal '$RuntimeParent'"
    }
}
Write-Host ("CAP-6b4 contract (c) PASS (runtime subdir '$RuntimeSubdir' under parent " +
    "'$RuntimeParent' authored once, installed by fixed.iss, reclaimed by two " +
    "ownership-gated [InstallDelete] entries, matched by $($subdirConsumers.Count) " +
    'consumer(s))')

# --- (d) the fixed profile's [Files] ORDER -----------------------------------
# The order is read from DIRECTIVE lines only. Taking indexes into the
# raw file text would let a header comment that merely MENTIONS the gate
# or the runtime Source line set the index and silently invert the
# proof - and this file's header discusses both at length.
$fixedDirectives = @(Get-DirectiveLines 'tools/setup/fixed.iss')
function Get-DirectiveIndex([string[]]$Lines, [string]$Needle, [string]$What) {
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Contains($Needle)) { return $i }
    }
    throw "fixed.iss has no directive line for $What (looked for '$Needle')"
}
$gateIdx = Get-DirectiveIndex $fixedDirectives 'BeforeInstall: FixedRuntimeGate' `
    'the verdict entry wired to FixedRuntimeGate'
$payloadIdx = Get-DirectiveIndex $fixedDirectives '#include "pwebapppayload.issi"' `
    'the shared payload include'
$treeIdx = Get-DirectiveIndex $fixedDirectives 'Source: "{#PWEB_RUNTIME_DIR}\*"' `
    'the staged runtime tree'
if ($payloadIdx -lt $gateIdx) {
    throw ('FIXED [Files] ORDER BROKEN: fixed.iss includes the shared release ' +
        'triple BEFORE its verdict gate. Measured with the pinned ISCC 6.7.3: a ' +
        'failed Evergreen -> fixed switch then leaves a fixed-mode releaseapp.exe ' +
        'behind with NO runtime tree and a marker still reading the source ' +
        'profile - the mixed, broken install matrix rows F3/F3b exist to forbid')
}
# and the runtime tree must land BEFORE the gate: the gate verifies the
# DEPLOYED bytes, which is the only thing it verifies
if ($treeIdx -gt $gateIdx) {
    throw ('fixed.iss deploys the runtime tree AFTER its verdict gate - the gate ' +
        'would then verify a tree that has not landed')
}
# every profile consumes the shared payload include exactly once, so
# the triple can never fork between modes
foreach ($rel in 'tools/setup/pwebprovgate.issi', 'tools/setup/fixed.iss') {
    $n = @([regex]::Matches((Get-Text $rel),
        '(?m)^#include\s+"pwebapppayload\.issi"\s*$')).Count
    if ($n -ne 1) {
        throw "$rel includes the shared payload include $n time(s); exactly one is required"
    }
}
if ((Get-Text 'tools/setup/pwebappsetup.issi') -match '(?m)^Source:\s') {
    throw ('pwebappsetup.issi authors [Files] entries again - the release triple ' +
        'must live only in pwebapppayload.issi so each profile controls its position')
}
Write-Host ('CAP-6b4 contract (d) PASS (fixed.iss order: runtime tree -> verdict gate ' +
    '-> shared release triple; both profiles include the triple exactly once)')

# --- (e) no Evergreen uninstall path anywhere --------------------------------
# The shared Evergreen runtime is machine state this product does not
# own: nothing here may uninstall, repair or force-remove it, in a
# setup manifest or in a gate script.
$EvergreenSweep = @(Get-ChildItem -Path (Join-Path $RepoRoot 'tools/setup'),
        (Join-Path $RepoRoot 'test/cap6b'), (Join-Path $RepoRoot 'test/cap6b1'),
        (Join-Path $RepoRoot 'test/cap6b2'), (Join-Path $RepoRoot 'test/cap6b3'),
        (Join-Path $RepoRoot 'test/cap6b4') `
        -Recurse -File -Include '*.ps1', '*.iss', '*.issi', '*.pas' |
    ForEach-Object { $_.FullName })
$EvergreenSweep += (Join-Path $RepoRoot 'tools/build-windows-profiles.ps1')
# the needles are concatenated so this gate cannot match its own source
# (the ratified ci.yml floating-ref-guard idiom) - it sweeps test/cap6b4
# too, and a self-hit would make the proof vacuous rather than strict
$evgPattern = ('--unin' + 'stall|/unin' + 'stall|MicrosoftEdge' + 'Update|' +
    'EdgeUp' + 'date\\Clients|msedgeup' + 'date|' +
    'Uninstall-Pac' + 'kage|msi' + 'exec')
$evgHits = @(Select-String -Path $EvergreenSweep -Pattern $evgPattern `
    -CaseSensitive:$false)
if ($evgHits) {
    $evgHits | ForEach-Object {
        Write-Host "FORBIDDEN EVERGREEN UNINSTALL PATH: $($_.Path):$($_.LineNumber): $($_.Line.Trim())"
    }
    throw ('CAP-6b4 no-Evergreen-uninstall proof failed - the shared runtime is ' +
        'machine state this product does not own')
}
Write-Host ("CAP-6b4 contract (e) PASS (no Evergreen uninstall/repair path in " +
    "$($EvergreenSweep.Count) swept source(s))")

# --- (f) no user-data deletion anywhere --------------------------------------
# %APPDATA%\releaseapp.exe is the WebView2 default user-data folder,
# derived from the executable name. It is SHARED by all three modes and
# PRESERVED by uninstall: an uninstall that deleted it would destroy a
# user's application state on a mere profile switch.
# the ban must cover EVERY setup manifest, not a hand-listed subset:
# [UninstallDelete] is the one section that could delete user data at
# uninstall time, and a profile manifest omitted from the list would
# carry one while this contract still reported PASS
foreach ($rel in $SetupSources) {
    if ((Get-Text $rel) -match '(?mi)^\s*\[UninstallDelete\]') {
        throw ("$rel authors an [UninstallDelete] section - uninstall removes " +
            'exactly what it installed, and never user data')
    }
}
$userDataHits = @()
foreach ($rel in $SetupSources) {
    foreach ($line in (Get-DirectiveLines $rel)) {
        if ($line -match '(?i)\{userappdata\}|\{localappdata\}\\Microsoft\\Edge|releaseapp\.exe\\') {
            $userDataHits += "${rel}: $($line.Trim())"
        }
    }
}
# {app} itself may never be the target of a bulk delete either: that is
# the install dir, not a scratch space, and Inno's own uninstaller
# already removes exactly what it recorded
foreach ($line in (Get-DirectiveLines 'tools/setup/pwebprovgate.issi')) {
    if ($line -match '^\s*Type:\s*filesandordirs;\s*Name:\s*"\{app\}"\s*$') {
        $userDataHits += "pwebprovgate.issi: bulk delete of {app}: $($line.Trim())"
    }
}
if ($userDataHits) {
    $userDataHits | ForEach-Object { Write-Host "FORBIDDEN USER-DATA TARGET: $_" }
    throw 'CAP-6b4 no-user-data-deletion proof failed'
}
# no gate script may remove it either - only the matrix may CREATE a
# sentinel inside it, and it must prove the folder survives uninstall
$gateScripts = @(Get-ChildItem -Path (Join-Path $RepoRoot 'test/cap6b1'),
        (Join-Path $RepoRoot 'test/cap6b2'), (Join-Path $RepoRoot 'test/cap6b3'),
        (Join-Path $RepoRoot 'test/cap6b4') -Recurse -File -Include '*.ps1' |
    ForEach-Object { $_.FullName })
# concatenated for the same reason as (e): this gate sweeps its own
# directory, and a self-hit would make the proof vacuous
$rmNeedle = 'Remove-' + 'Item'
$rmVar = 'APP' + 'DATA'
$rmHits = @(Select-String -Path $gateScripts `
    -Pattern "$rmNeedle[^\r\n]*-Recurse[^\r\n]*$rmVar" -CaseSensitive:$false)
$rmHits += @(Select-String -Path $gateScripts `
    -Pattern "$rmNeedle[^\r\n]*$rmVar[^\r\n]*-Recurse" -CaseSensitive:$false)
if ($rmHits) {
    $rmHits | ForEach-Object {
        Write-Host "FORBIDDEN USER-DATA DELETION: $($_.Path):$($_.LineNumber): $($_.Line.Trim())"
    }
    throw 'a gate script recursively deletes the shared WebView2 user-data folder'
}
Write-Host ("CAP-6b4 contract (f) PASS (no [UninstallDelete], no user-data target in " +
    "$($SetupSources.Count) manifest(s), no recursive user-data deletion in " +
    "$($gateScripts.Count) gate script(s))")


# --- (g) prior runtime gates, AGGREGATED from repository evidence ------------
# CAP-6b4 integrates three shards. Two of their authoritative external
# gates were WAIVED by explicit human decision and one was genuinely
# CLEARED by a transcript; an integration shard that reported "all
# green" would silently upgrade a waiver into a proof. So the verdicts
# are read out of the append-only ledger and reported as DISTINCT
# verdicts - and if a record is missing, this gate STOPS rather than
# assuming closure.
$LedgerRel = '_bmad-output/implementation-artifacts/deferred-work.md'
$ledgerFile = Join-Path $RepoRoot $LedgerRel
if (-not (Test-Path -LiteralPath $ledgerFile)) {
    throw ("the repository-evidence ledger is missing ($LedgerRel) - CAP-6b4 " +
        'STOPS rather than assuming its prior gates closed')
}
# the ledger is append-only, so a gate's CURRENT verdict is its LAST record
$records = @()
$cur = $null
foreach ($line in ((Get-Content -LiteralPath $ledgerFile -Raw) -split "`r?`n")) {
    if ($line -match '^\s*-\s+source_spec:') {
        if ($null -ne $cur) { $records += , $cur }
        $cur = [System.Text.StringBuilder]::new()
    }
    if ($null -ne $cur) { [void]$cur.AppendLine($line) }
}
if ($null -ne $cur) { $records += , $cur }
if ($records.Count -eq 0) {
    throw "the repository-evidence ledger ($LedgerRel) contains no records - CAP-6b4 STOPS"
}
$recordText = @($records | ForEach-Object { $_.ToString() })

# Each prior gate is identified by the grep-able transcript marker only
# IT can carry - never by a prose fragment, which any rewording would
# turn into a spurious STOP - and the matched record must additionally
# name that shard's own spec, so a marker quoted inside some unrelated
# record can never be mistaken for the gate's verdict.
$PriorGates = @(
    @{ Gate = 'CAP-6b1 clean-machine (Evergreen Bootstrapper provisioning)'
       Marker = 'CAP6B1_CLEAN_MACHINE_PASS'
       Spec = 'spec-phase-6b1-normal-evergreen-installer.md'
       Expect = 'CLEARED'
       Means = 'PASS - a genuine runtime-absent transcript exists' },
    @{ Gate = 'CAP-6b2 offline clean-machine (network-disabled VM)'
       Marker = 'CAP6B2_OFFLINE_CLEAN_MACHINE_PASS'
       Spec = 'spec-phase-6b2-offline-evergreen-installer.md'
       Expect = 'WAIVED'
       Means = 'WAIVED - no transcript; waived by explicit human decision' },
    @{ Gate = 'CAP-6b3 real runtime Gate B/C (no-Evergreen VM, Windows 10 AppContainer)'
       Marker = 'CAP6B3_CLEAN_MACHINE_PASS'
       Spec = 'spec-phase-6b3-fixed-runtime-profile.md'
       Expect = 'WAIVED'
       Means = 'WAIVED - no transcript; waived by explicit human decision' }
)
$verdictLines = @()
# the verdicts are read OUT OF THE LEDGER, and distinctness is asserted
# on what was read - asserting it on the expectations three lines above
# would only prove that this file disagrees with itself
$observedVerdicts = @()
foreach ($g in $PriorGates) {
    $hits = @($recordText | Where-Object {
        $_.Contains($g.Marker) -and $_.Contains($g.Spec) })
    if ($hits.Count -eq 0) {
        throw ("$LedgerRel carries NO record for the $($g.Gate) gate (marker " +
            "'$($g.Marker)' in a record sourced from $($g.Spec)) - CAP-6b4 STOPS " +
            'rather than assuming closure')
    }
    # append-only ledger: a gate's CURRENT verdict is its LAST record
    $last = $hits[-1]
    if ($last -notmatch '(?m)^\s*summary:\s+([A-Z][A-Z-]+)\b') {
        throw ("the latest $($g.Gate) record carries no verdict token " +
            '(RESOLVED / CLEARED / WAIVED / OUTSTANDING) - CAP-6b4 STOPS')
    }
    $verdict = $Matches[1]
    $observedVerdicts += $verdict
    if ($verdict -cne $g.Expect) {
        throw ("the $($g.Gate) gate now reads '$verdict' in $LedgerRel; CAP-6b4 " +
            "aggregated it as '$($g.Expect)'. A prior external gate's verdict may " +
            'only change by a deliberate human act - re-ratify this contract ' +
            'together with the ledger, so a waiver can never be silently upgraded ' +
            'into a proof')
    }
    $verdictLines += "  $($g.Gate): $($g.Means)  [ledger verdict: $verdict]"
}
# the verdicts READ FROM THE LEDGER must stay DISTINGUISHABLE - a ledger
# that had quietly levelled them into one word is the exact failure this
# contract exists to catch
$distinct = @($observedVerdicts | Sort-Object -Unique)
if ($distinct.Count -lt 2) {
    throw ("the prior-gate verdicts READ FROM $LedgerRel collapsed into the single " +
        "token '$($distinct[0])' - CAP-6b1's PASS and CAP-6b2/6b3's WAIVED must " +
        'never be merged into "tested"')
}
Write-Host ''
Write-Host 'CAP-6b4 prior runtime gates (AGGREGATED from repository evidence, never re-performed):'
$verdictLines | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host ("CAP-6b4 contract (g) PASS ($($PriorGates.Count) prior runtime gates read " +
    "from $LedgerRel as $($distinct.Count) DISTINCT ledger verdicts: " +
    "$($distinct -join ', '))")
if ($env:GITHUB_STEP_SUMMARY) {
    (@('### CAP-6b4 prior runtime gates (aggregated, never re-performed)', '') +
     @($PriorGates | ForEach-Object { "- **$($_.Gate)**: $($_.Means)" })) -join "`n" |
        Out-File -Append $env:GITHUB_STEP_SUMMARY
}

Write-Host 'CAP6B4_CONTRACTS_PASS'
