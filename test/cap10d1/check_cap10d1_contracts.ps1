# CAP-10D1 contract cross-checks: the claims `pweb build --profile` makes
# about the tree it is added to, measured over the SOURCE.
#
# Checkout-only: no toolchain, no network, no display, no build output. It
# runs in every platform job and on any dev host, before anything is
# compiled, so a violation is a red step rather than a red suite an hour
# later.
#
# WHAT IT MEASURES, and why each one is here rather than in a suite:
#
#   1  THE PINS ARE THE LOCKS'. Every constant in pweb.cli.packpins is
#      compared against innosetup.lock, webview2-runtime.lock, webview.lock
#      and the provisioning unit's own timeout. A pin nobody cross-checks is
#      a number somebody typed.
#   2  ONE EXECUTION PATH, at five. The set of production units that call
#      PWebCliExecute is exactly the ratified five, pweb.cli.package is the
#      one CAP-10D1 added, and pweb.cli.build STILL names no process API at
#      all. A suite could not say this: it is a claim about units that are
#      NOT reachable.
#   3  THE ANTI-FORK EQUALITY. The [Code] region of the generic provisioning
#      include is byte-identical to tools/setup/pwebprovgate.issi's, and
#      app-fixed.iss's to fixed.iss's. A CAP-13 gate body that moves without
#      its twin is a red step rather than a divergence found on a user's
#      machine.
#   4  NOTHING SIGNS, READS A CREDENTIAL OR REACHES A NETWORK. Every unit on
#      the packaging path and every D1 manifest is swept for every spelling.
#   5  THE FAULT SEAM CANNOT SHIP. The rollback fault define appears in a
#      ratified handful of files and in no CI step that produces a shipped
#      binary. Its spelling is never written out in this file - the needle
#      is concatenated, exactly as the ci.yml floating-ref guard is, so this
#      sweep can never satisfy itself.
#   6  THE GRAMMAR. --profile is ratified; the eight options CAP-10D0
#      refused are still refused; the usage taxonomy is still thirteen.
#   7  THE LEDGER, at the source: pweb.cli.package resolves no toolset
#      (C1-11 a), and no unit under tools/pweb writes to Output/ErrOutput
#      outside pweb.pas's two flushing helpers (C1-11 f).
#   8  THE CAP-13 FILES ARE UNTOUCHED - asserted by the three literals this
#      shard's justification rests on still being literals.
#   9  THE DOCUMENTS.
#
# Emits build/cap10d1/contracts.json and exits nonzero on any violation.
#
# Usage: pwsh test/cap10d1/check_cap10d1_contracts.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
$facts = [ordered]@{}
function Violation([string]$Text) {
    $violations.Add($Text)
    Write-Host "VIOLATION: $Text"
}
function ReadText([string]$Rel) {
    if (-not (Test-Path -LiteralPath $Rel)) { throw "missing $Rel" }
    return [System.IO.File]::ReadAllText($Rel)
}
# every comparison of two checked-in text files normalises line endings
# first: core.autocrlf gives a Windows checkout CRLF and a POSIX one LF, and
# a byte comparison that disagreed with itself per platform would be the
# four-target equality defect CAP-10B1 measured in a different costume
function Lf([string]$Text) { return $Text.Replace("`r`n", "`n") }

$packPins = ReadText 'tools/pweb/pweb.cli.packpins.pas'
# a constant's VALUE, whether it was written on one line or as a Pascal
# concatenation across several: a house style that wraps at 79 columns must
# not be able to hide a pin from the gate that checks it
function PinConst([string]$Name) {
    $m = [regex]::Match($packPins,
        "(?ms)^\s*$Name\s*=\s*((?:'[^']*'\s*\+\s*)*'[^']*'|\d+)\s*;")
    if (-not $m.Success) { return $null }
    $raw = $m.Groups[1].Value
    if ($raw -match '^\d+$') { return $raw }
    $parts = [regex]::Matches($raw, "'([^']*)'")
    $out = ''
    foreach ($p in $parts) { $out += $p.Groups[1].Value }
    return $out
}

# --- 1. the pins are the locks' --------------------------------------------
# innosetup.lock
$inno = @{}
foreach ($line in (Get-Content 'innosetup.lock')) {
    $t = $line.Trim()
    if (($t -eq '') -or $t.StartsWith('#')) { continue }
    $k, $v = $t -split '=', 2
    $inno[$k.Trim()] = $v.Trim()
}
$pairs = [ordered]@{
    PWEB_PACK_ISCC_VERSION       = $inno['version']
    PWEB_PACK_ISCC_INSTALLER_SHA = $inno['sha256']
}
# webview2-runtime.lock, one strict pass over its artifact blocks
$wv2 = @{}
$section = ''
foreach ($line in (Get-Content 'webview2-runtime.lock')) {
    $t = $line.Trim()
    if (($t -eq '') -or $t.StartsWith('#')) { continue }
    $k, $v = $t -split '=', 2
    $k = $k.Trim(); $v = $v.Trim()
    if ($k -ceq 'artifact') { $section = $v; continue }
    if ($section -ne '') { $wv2["$section/$k"] = $v }
}
$pairs['PWEB_PACK_WV2_BOOTSTRAPPER']       = $wv2['evergreen-bootstrapper/filename']
$pairs['PWEB_PACK_WV2_BOOTSTRAPPER_BYTES'] = $wv2['evergreen-bootstrapper/size']
$pairs['PWEB_PACK_WV2_BOOTSTRAPPER_SHA']   = $wv2['evergreen-bootstrapper/sha256']
$pairs['PWEB_PACK_WV2_STANDALONE']         = $wv2['evergreen-standalone-x64/filename']
$pairs['PWEB_PACK_WV2_STANDALONE_BYTES']   = $wv2['evergreen-standalone-x64/size']
$pairs['PWEB_PACK_WV2_STANDALONE_SHA']     = $wv2['evergreen-standalone-x64/sha256']
$pairs['PWEB_PACK_WV2_FIXED_CAB']          = $wv2['webview2-fixed-runtime-x64/filename']
$pairs['PWEB_PACK_WV2_FIXED_BYTES']        = $wv2['webview2-fixed-runtime-x64/size']
$pairs['PWEB_PACK_WV2_FIXED_SHA']          = $wv2['webview2-fixed-runtime-x64/sha256']
$pairs['PWEB_PACK_WV2_FIXED_VERSION']      = $wv2['webview2-fixed-runtime-x64/version']
$pairs['PWEB_PACK_WV2_SUBJECT']            = $wv2['evergreen-bootstrapper/authenticode-subject']
# webview.lock: the SDK version the loader digest is anchored to
$sdkVersion = ''
foreach ($line in (Get-Content 'webview.lock')) {
    $t = $line.Trim()
    if ($t -cmatch '^webview2-sdk\s*=\s*(.+)$') { $sdkVersion = $Matches[1].Trim() }
}
# NOT compared against a Pascal constant: CAP-10A's contract check refuses a
# second copy of the WebView2 build number anywhere under tools/pweb, because
# that number already has one owner (the CAP-6b0 detector). The anchor lives
# HERE instead - the loader digest below is a CAP-10D1 ratification of the
# file THIS SDK version carries, so a bump of the lock has to come past this
# line before it can be inherited silently.
$facts['webview2_sdk_version'] = $sdkVersion
if ($sdkVersion -cne '1.0.1587' + '.40') {
    Violation ("webview.lock pins WebView2 SDK $sdkVersion; the CAP-10D1 " +
        'loader digest was ratified against 1.0.1587.40 - re-ratify ' +
        'PWEB_PACK_WV2_LOADER_SHA against the new tree, then move this line')
}
# the provisioning unit is the SINGLE source of the bounded helper wait, the
# same cross-check test/cap6b1/build_normal_setup.ps1 performs
$provUnit = ReadText 'src/platform/windows/pweb.platform.webview2.provision.pas'
if ($provUnit -match 'PWEB_WV2_INSTALL_TIMEOUT_MS\s*=\s*(\d+)\s*;') {
    $pairs['PWEB_PACK_WV2_TIMEOUT_MS'] = $Matches[1]
} else {
    Violation 'PWEB_WV2_INSTALL_TIMEOUT_MS could not be read from the provisioning unit'
}
$mismatched = @()
foreach ($k in $pairs.Keys) {
    $want = "$($pairs[$k])"
    $have = PinConst $k
    if ($null -eq $have) {
        Violation "pweb.cli.packpins does not declare $k"
        $mismatched += $k
    } elseif ($have -cne $want) {
        Violation "$k is '$have'; its lock says '$want'"
        $mismatched += $k
    }
}
$facts['pins_checked'] = $pairs.Count
$facts['pins_mismatched'] = ($mismatched -join ',')
# the fixed tree name is DERIVED from the pinned version by Microsoft's own
# naming, and CAP-6b3 spells that derivation out; here the literal is
# required to agree with it
$wantTree = "Microsoft.WebView2.FixedVersionRuntime.$($pairs['PWEB_PACK_WV2_FIXED_VERSION']).x64"
if ((PinConst 'PWEB_PACK_WV2_FIXED_TREE') -cne $wantTree) {
    Violation "PWEB_PACK_WV2_FIXED_TREE is not '$wantTree'"
}
# and the loader digest is a D1 ratification: it is checked against the FILE
# only where that file exists (a Windows job that ran tools/build-webview-dll.ps1)
$loader = 'build/webview-build-cap4w/_deps/microsoft_web_webview2-src/build/native/x64/WebView2Loader.dll'
if (Test-Path -LiteralPath $loader) {
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $loader).Hash.ToLowerInvariant()
    $facts['loader_present'] = 'true'
    if ($sha -cne (PinConst 'PWEB_PACK_WV2_LOADER_SHA')) {
        Violation ("PWEB_PACK_WV2_LOADER_SHA is not the pinned SDK loader's " +
            "digest: the tree hashes to $sha")
    }
    if ((Get-Item -LiteralPath $loader).Length -ne
            [int64](PinConst 'PWEB_PACK_WV2_LOADER_BYTES')) {
        Violation 'PWEB_PACK_WV2_LOADER_BYTES is not the pinned loader''s size'
    }
} else {
    $facts['loader_present'] = 'false'
}
# NO URL, EVER. The locks keep the addresses; a build path that cannot name
# one cannot reach one
foreach ($rel in 'tools/pweb/pweb.cli.packpins.pas',
                 'tools/pweb/pweb.cli.package.pas',
                 'tools/pweb/pweb.cli.tar.pas') {
    if ((ReadText $rel) -match '(?i)https?://') {
        Violation "$rel names a URL - the packaging path must carry none"
    }
}
$facts['packaging_urls'] = 0

# --- 2. one execution path, at five ----------------------------------------
$callers = New-Object System.Collections.Generic.List[string]
foreach ($f in (Get-ChildItem -Path 'tools/pweb' -Filter '*.pas')) {
    if ($f.Name -eq 'pweb.cli.process.pas') { continue }
    $t = [System.IO.File]::ReadAllText($f.FullName)
    if ($t -match 'PWebCliExecute\s*\(') { $callers.Add($f.Name) }
}
$callerList = (($callers | Sort-Object) -join ',')
$facts['execute_callers'] = $callerList
$expectedCallers = 'pweb.cli.dev.pas,pweb.cli.package.pas,' +
    'pweb.cli.pipeline.pas,pweb.cli.probe.pas,pweb.cli.run.pas'
if ($callerList -cne $expectedCallers) {
    Violation ("the set of PWebCliExecute callers is [$callerList]; CAP-10D1 " +
        "ratifies [$expectedCallers] - four inherited plus the packaging " +
        'driver, and no sixth')
}
# the D0 property that mattered most, re-measured rather than inherited
$buildSrc = ReadText 'tools/pweb/pweb.cli.build.pas'
$procApis = @('PWebCliExecute', 'PWebCliChildSpawn', 'PWebCliChildWait',
    'PWebCliChildStop', 'PWebCliChildKill', 'CreateProcess', 'ShellExecute',
    'fpExecv', 'fpExecve', 'fpFork', 'popen', 'ExecuteProcess', 'RunCommand')
$hits = @()
foreach ($api in $procApis) {
    if ($buildSrc -match [regex]::Escape($api)) { $hits += $api }
}
$facts['build_driver_process_apis'] = ($hits -join ',')
if ($hits.Count -gt 0) {
    Violation ('pweb.cli.build names a process API: ' + ($hits -join ', '))
}
if ($buildSrc -match '\{\$ifdef\s+(OSWINDOWS|UNIX|DARWIN|LINUX)') {
    Violation 'pweb.cli.build carries a platform conditional'
}
# the packaging driver runs children ONLY in the supervise profile: a probe
# profile here would be a bounded capture, which is not what a fifteen-minute
# compile of a 690 MB tree needs and not what a stop request must reach
$packSrc = ReadText 'tools/pweb/pweb.cli.package.pas'
if ($packSrc -notmatch 'pepSupervise') {
    Violation 'pweb.cli.package does not run its children in pepSupervise'
}
if ($packSrc -match 'spec\.Profile\s*:=\s*pepProbe') {
    Violation 'pweb.cli.package runs a child in the probe profile'
}

# --- 3. the anti-fork equality ---------------------------------------------
function CodeRegion([string]$Rel) {
    $lines = (Lf (ReadText $Rel)) -split "`n"
    $at = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -ceq '[Code]') { $at = $i; break }
    }
    if ($at -lt 0) { return $null }
    return (($lines[$at..($lines.Count - 1)]) -join "`n").TrimEnd("`n")
}
$twins = @(
    @{ A = 'tools/setup/pwebprovgate.issi'
       B = 'tools/setup/app/pwebappprov.issi'
       What = 'the provisioning gate' },
    @{ A = 'tools/setup/fixed.iss'
       B = 'tools/setup/app/app-fixed.iss'
       What = 'the fixed-runtime verdict gate' }
)
foreach ($t in $twins) {
    $a = CodeRegion $t.A
    $b = CodeRegion $t.B
    if (($null -eq $a) -or ($null -eq $b)) {
        Violation "$($t.What): one of the two files authors no [Code] section"
    } elseif ($a -cne $b) {
        Violation ("$($t.What) HAS FORKED: $($t.B)'s [Code] is not " +
            "byte-identical to $($t.A)'s. CAP-10D1 may not change the CAP-13 " +
            'body; if that body moved, move its twin in the same commit')
    }
}
$facts['code_twins'] = $twins.Count
# and the fixed [Files] ORDER, the CAP-6b4 rule applied to the generic
# manifest: runtime tree -> verdict gate -> shared release triple
$fixedApp = Lf (ReadText 'tools/setup/app/app-fixed.iss')
$idxTree = $fixedApp.IndexOf('Source: "{#PWEB_RUNTIME_DIR}\*"')
$idxGate = $fixedApp.IndexOf('BeforeInstall: FixedRuntimeGate')
$idxTriple = $fixedApp.IndexOf('#include "pwebapptriple.issi"')
if (($idxTree -lt 0) -or ($idxGate -lt 0) -or ($idxTriple -lt 0)) {
    Violation 'app-fixed.iss is missing the runtime tree, the gate or the triple'
} elseif (-not (($idxTree -lt $idxGate) -and ($idxGate -lt $idxTriple))) {
    Violation ('app-fixed.iss [Files] ORDER BROKEN: the ratified order is ' +
        'runtime tree -> verdict gate -> shared release triple, for the ' +
        'reason CAP-6b4 measured with the pinned ISCC 6.7.3')
}
# every generic profile consumes the shared includes exactly once
foreach ($rel in 'tools/setup/app/pwebappprov.issi',
                 'tools/setup/app/app-fixed.iss') {
    $n = @([regex]::Matches((ReadText $rel),
        '(?m)^#include\s+"pwebapptriple\.issi"\s*$')).Count
    if ($n -ne 1) {
        Violation "$rel includes the shared payload $n time(s); exactly one"
    }
}
# the identity include REQUIRES every value and defaults none of the four
# that reach a user's machine
$identity = ReadText 'tools/setup/app/pwebappid.issi'
foreach ($name in 'PWEB_APP_ID', 'PWEB_APP_NAME', 'PWEB_APP_VERSION',
                  'PWEB_INSTALL_VENDOR', 'PWEB_INSTALL_APP',
                  'PWEB_MARKER_KEY', 'PWEB_PROFILE', 'PWEB_SETUP_BASENAME') {
    if ($identity -notmatch "(?m)^\s*#ifndef\s+$name\s*$") {
        Violation "pwebappid.issi does not guard $name with #ifndef"
    }
    if ($identity -match "(?m)^\s*#define\s+$name\s+") {
        Violation ("pwebappid.issi DEFAULTS $name - a default here silently " +
            "stamps a wrong identity onto a user's machine")
    }
}
if ($identity -notmatch '(?m)^\s*#if\s+Pos\("\|"\s*\+\s*PWEB_PROFILE\s*\+\s*"\|",\s*PWEB_PROFILE_SET\)\s*==\s*0\s*$') {
    Violation 'pwebappid.issi does not validate PWEB_PROFILE case-sensitively'
}
if ($identity -notmatch 'LowerCase\(PWEB_SETUP_BASENAME\)') {
    Violation 'pwebappid.issi does not ban the shimmed "setup" basename'
}
$m = [regex]::Match($identity, '(?m)^#define\s+PWEB_PROFILE_SET\s+"([^"]+)"\s*$')
if (-not $m.Success) {
    Violation 'pwebappid.issi does not author PWEB_PROFILE_SET'
} elseif ($m.Groups[1].Value -cne '|normal|offline|fixed-runtime|') {
    Violation ('the generic profile set is not the CAP-13 one: ' +
        $m.Groups[1].Value)
}
$facts['generic_manifests'] = (Get-ChildItem 'tools/setup/app' -File).Count

# --- 4. nothing signs, reads a credential or reaches a network -------------
$packPath = @('tools/pweb/pweb.cli.package.pas', 'tools/pweb/pweb.cli.tar.pas',
    'tools/pweb/pweb.cli.packpins.pas', 'tools/pweb/pweb.cli.build.pas')
$packPath += (Get-ChildItem 'tools/setup/app' -File |
    ForEach-Object { "tools/setup/app/$($_.Name)" })
# the needles are concatenated so this gate cannot match its own source -
# the ratified ci.yml floating-ref-guard idiom, reused
$signWords = @(('sign' + 'tool'), ('code' + 'sign'), ('notary' + 'tool'),
    ('notari' + 'ze'), ('key' + 'chain'), ('security find-' + 'identity'),
    ('Cred' + 'Read'), ('Cred' + 'Write'), ('cert' + 'util'),
    ('SignTo' + 'ol='), ('SignedUnin' + 'staller'), ('--si' + 'gn'),
    ('Developer ' + 'ID'))
$netWords = @(('Invoke-Web' + 'Request'), ('THttp' + 'Client'),
    ('win' + 'http'), ('Download' + 'File'), ('URLDownload' + 'ToFile'),
    ('cur' + 'l '), ('wg' + 'et '), ('http' + '://'), ('mormot.net.' + 'client'))
$leaked = @()
foreach ($rel in $packPath) {
    $t = ReadText $rel
    foreach ($w in ($signWords + $netWords)) {
        if ($t -match [regex]::Escape($w)) { $leaked += "${rel}:${w}" }
    }
}
$facts['signing_or_network_hits'] = ($leaked -join ',')
if ($leaked.Count -gt 0) {
    Violation ('the packaging path names a signing, credential or network ' +
        'API: ' + ($leaked -join ', '))
}
# and no D1 manifest may author a [Run] entry or an [UninstallDelete]: the
# first would launch something after a setup that is meant to end, the second
# would delete user data on an uninstall
foreach ($rel in (Get-ChildItem 'tools/setup/app' -File |
                  ForEach-Object { "tools/setup/app/$($_.Name)" })) {
    $t = ReadText $rel
    if ($t -match '(?mi)^\s*\[Run\]') {
        Violation "$rel authors a [Run] section"
    }
    if ($t -match '(?mi)^\s*\[UninstallDelete\]') {
        Violation "$rel authors an [UninstallDelete] section"
    }
}

# --- 5. the fault seam cannot ship -----------------------------------------
# the needle is concatenated so this gate cannot match its OWN source - the
# ratified ci.yml floating-ref-guard idiom. Without it the sweep would
# always find itself, and a proof that includes its own prover is vacuous.
$faultNeedle = 'PWEB_LAYOUT' + '_FAULTS'
$faultFiles = @()
foreach ($f in (Get-ChildItem -Path 'test', 'tools', '.github' -Recurse -File `
                -Include '*.ps1', '*.sh', '*.yml', '*.pas')) {
    $rel = $f.FullName.Substring($repoRoot.Length + 1).Replace('\', '/')
    $t = [System.IO.File]::ReadAllText($f.FullName)
    if ($t -match [regex]::Escape($faultNeedle)) { $faultFiles += $rel }
}
$facts['fault_seam_files'] = (($faultFiles | Sort-Object) -join ',')
# the ratified five: the seam itself, the suite that arms it, the runner
# whose header documents it, and the two build scripts that compile them.
# Anything else could carry the define into a shipped binary.
$expectedFault = 'test/cap10d1/build_cap10d1.ps1,test/cap10d1/build_cap10d1.sh,' +
    'test/cap10d1/d1tests.pas,test/cap10d1/pweb.test.pack.pas,' +
    'tools/pweb/pweb.cli.layout.pas'
if ((($faultFiles | Sort-Object) -join ',') -cne $expectedFault) {
    Violation ('the rollback fault define appears in [' +
        (($faultFiles | Sort-Object) -join ', ') + ']; the ratified set is ' +
        'the seam itself, the suite that arms it, its runner and the two ' +
        'build scripts that compile them - anything else could ship it')
}
# and the ONLY compile commands that pass it are those two build scripts
foreach ($rel in 'test/cap10d1/build_cap10d1.ps1',
                 'test/cap10d1/build_cap10d1.sh') {
    if ((ReadText $rel) -notmatch ('-d' + [regex]::Escape($faultNeedle))) {
        Violation "$rel no longer passes the fault define to the suite compile"
    }
}
# and it is DECLARED inside the guard, so a production build has no such
# variable at all rather than one that defaults to False
$layoutSrc = ReadText 'tools/pweb/pweb.cli.layout.pas'
if ($layoutSrc -notmatch ('(?ms)\{\$ifdef ' + [regex]::Escape($faultNeedle) +
        '\}.*?PWebCliLayoutFailCommit.*?\{\$endif\}')) {
    Violation 'the rollback seam is not guarded by the fault define'
}

# --- 6. the grammar ---------------------------------------------------------
$argsSrc = ReadText 'tools/pweb/pweb.cli.args.pas'
$reportSrc = ReadText 'tools/pweb/pweb.cli.report.pas'
if ($argsSrc -notmatch "name = '--profile'") {
    Violation 'pweb.cli.args does not accept --profile'
}
if ($reportSrc -notmatch '--profile') {
    Violation 'pweb.cli.report does not advertise --profile'
}
# the eight CAP-10D0 refused and CAP-10D1 does not ratify
$unratified = @('--target', '--clean', '--release', '--debug', '--watch',
    '--install', '--output', '--force')
$present = @()
foreach ($o in $unratified) {
    if ($argsSrc -match "name = '$o'") { $present += $o }
}
$facts['unratified_options_present'] = ($present -join ',')
if ($present.Count -gt 0) {
    Violation ('pweb.cli.args defines an option CAP-10D1 did not ratify: ' +
        ($present -join ', '))
}
# NO NEW USAGE CAUSE: the per-target refusal is a COMMAND fact, answered
# after parsing, which is what keeps one grammar identical on four platforms
$usageMatch = [regex]::Match($argsSrc, 'TPWebCliUsage = \(\s*([^)]*)\)')
if ($usageMatch.Success) {
    $causes = @(($usageMatch.Groups[1].Value -split ',') |
        ForEach-Object { ($_ -replace '(?s)/{2,}[^\r\n]*', '').Trim() } |
        Where-Object { $_ -match '^pcu' })
    $facts['usage_causes'] = $causes.Count
    if ($causes.Count -ne 13) {
        Violation ("TPWebCliUsage has $($causes.Count) members; CAP-10A " +
            'ratified thirteen and CAP-10D1 adds none')
    }
}
# the four profile names, spelled once in the package unit and nowhere else
foreach ($p in 'normal', 'offline', 'fixed-runtime', 'archive') {
    if ($packSrc -notmatch "= '$p';") {
        Violation "pweb.cli.package does not spell the profile '$p'"
    }
}
if ($packSrc -match "'fixed'\s*;") {
    Violation ('pweb.cli.package spells `fixed`; the ratified name is ' +
        '`fixed-runtime`, which is what is written to the machine')
}
$facts['profiles'] = 'normal,offline,fixed-runtime,archive'
# the long-path bound, and the refusal wired to it
$toolchain = ReadText 'tools/pweb/pweb.cli.toolchain.pas'
$m = [regex]::Match($toolchain, 'PWEB_CLI_PIPE_MAX_ROOT_CHARS\s*=\s*(\d+)\s*;')
if (-not $m.Success) {
    Violation 'PWEB_CLI_PIPE_MAX_ROOT_CHARS is not declared'
} else {
    $facts['long_path_bound'] = $m.Groups[1].Value
}
$pipeSrc = ReadText 'tools/pweb/pweb.cli.pipeline.pas'
if ($pipeSrc -notmatch 'project_root_too_long') {
    Violation 'the pipeline does not refuse an over-long project root'
}
if ($pipeSrc -notmatch '(?s)pskOpen.*project_root_too_long') {
    Violation ('the long-path refusal is not on the `open` stage - it must ' +
        'fire before anything is written or spawned')
}
# the ten stages and the eight inherited bounds are STILL what they were
$stageMatch = [regex]::Match($pipeSrc, 'TPWebCliStageKind = \(\s*([^)]*)\)')
if ($stageMatch.Success) {
    $members = @(($stageMatch.Groups[1].Value -split ',') |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $facts['stage_count'] = $members.Count
    if ($members.Count -ne 10) {
        Violation ("TPWebCliStageKind has $($members.Count) members; " +
            'packaging is not a stage and CAP-10D1 adds none')
    }
}

# --- 7. the ledger, at the source ------------------------------------------
# C1-11 (a): the packaging preflight resolves ONE executable through the
# CAP-10A primitive and never through the requirement graph, which is why
# the toolset duplication is still on no path that needs collapsing
if ($packSrc -match 'PWebCliResolveToolset') {
    Violation ('pweb.cli.package resolves a TOOLSET; the preflight needs one ' +
        'executable and gets it from PWebCliResolveTool - see C1-11 (a)')
}
$facts['pack_resolves_toolset'] = 'false'
# C1-11 (f): the CLI has exactly TWO console write sites, both in pweb.pas
# and both immediately flushed, so a line-buffering setup would have no
# failing property to fix. pwebtemplates.pas is excluded BY NAME: it is the
# build-time pack builder, a separate program that is never linked into the
# CLI (test/cap10b0/check_cap10b0_contracts.ps1 measures that absence).
$writers = @()
foreach ($f in (Get-ChildItem -Path 'tools/pweb' -Filter '*.pas')) {
    if ($f.Name -eq 'pwebtemplates.pas') { continue }
    $t = [System.IO.File]::ReadAllText($f.FullName)
    if ($t -match '(?m)^\s*(Write|WriteLn)\s*\(') { $writers += $f.Name }
}
$facts['console_writers'] = (($writers | Sort-Object) -join ',')
if ((($writers | Sort-Object) -join ',') -cne 'pweb.pas') {
    Violation ('a unit other than pweb.pas writes to the console directly: ' +
        (($writers | Sort-Object) -join ', ') + ' -- every line goes through ' +
        'Emit/EmitErr, both of which flush (C1-11 f)')
}
$pwebSrc = ReadText 'tools/pweb/pweb.pas'
$writeSites = @([regex]::Matches($pwebSrc, '(?m)^\s*Write\s*\(')).Count
$flushSites = @([regex]::Matches($pwebSrc, '(?m)^\s*Flush\s*\(')).Count
$facts['console_write_sites'] = $writeSites
$facts['console_flush_sites'] = $flushSites
if (($writeSites -ne 2) -or ($flushSites -ne 2)) {
    Violation ("pweb.pas has $writeSites console write site(s) and " +
        "$flushSites flush(es); the ratified shape is Emit and EmitErr, " +
        'one write and one flush each (C1-11 f)')
}

# --- 8. the CAP-13 files are untouched -------------------------------------
# The three literals this shard's whole justification rests on. If any of
# them became a define, the generic set would have been unnecessary - and if
# one silently changed, a CAP-13 gate would fail somewhere far from here.
$cap13 = ReadText 'tools/setup/pwebappsetup.issi'
if ($cap13 -notmatch '(?m)^AppId=\{\{([0-9A-Fa-f-]+)\}\s*$') {
    Violation ('pwebappsetup.issi no longer authors a LITERAL AppId - the ' +
        'CAP-10D1 generic manifests exist because it does')
}
if ($cap13 -notmatch '(?m)^#define\s+PWEB_MARKER_KEY\s+"Software\\PWeb\\PWebRelease"\s*$') {
    Violation 'pwebappsetup.issi no longer pins the CAP-13 marker key literal'
}
if ((ReadText 'tools/setup/pwebapppayload.issi') -notmatch 'releaseapp\.exe') {
    Violation 'pwebapppayload.issi no longer names releaseapp.exe literally'
}
$facts['cap13_literals'] = 3

# --- 9. the documents -------------------------------------------------------
foreach ($doc in 'docs/distribution-contract.md', 'docs/index.md',
                 'docs/build-contract.md') {
    if (-not (Test-Path -LiteralPath $doc)) { Violation "missing $doc" }
}
$index = ReadText 'docs/index.md'
if (-not $index.Contains('distribution-contract.md')) {
    Violation 'docs/index.md does not cross-link distribution-contract.md'
}
$distDoc = ReadText 'docs/distribution-contract.md'
foreach ($phrase in 'pweb build --profile', 'fixed-runtime', 'archive',
                    'release-index.json', 'profile_not_for_target',
                    'com.apple.quarantine') {
    if (-not $distDoc.Contains($phrase)) {
        Violation "docs/distribution-contract.md does not record: $phrase"
    }
}
if (-not (ReadText 'docs/build-contract.md').Contains('--profile <name>')) {
    Violation 'docs/build-contract.md does not record the --profile grammar'
}
$facts['docs'] = 3

# --- verdict ----------------------------------------------------------------
New-Item -ItemType Directory -Force build/cap10d1 | Out-Null
$facts['violations'] = $violations.Count
$facts['verdict'] = if ($violations.Count -eq 0) { 'PASS' } else { 'FAIL' }
[System.IO.File]::WriteAllText('build/cap10d1/contracts.json',
    (($facts | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host ($facts | ConvertTo-Json -Depth 6)
if ($violations.Count -gt 0) {
    throw "CAP-10D1 contract cross-checks FAILED: $($violations.Count) violation(s)"
}
Write-Host '[CAP-10D1] contract cross-checks PASS'
