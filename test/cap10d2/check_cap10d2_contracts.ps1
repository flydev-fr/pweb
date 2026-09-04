# CAP-10D2 contract cross-checks: the SDK packager and the integrity model,
# measured at the SOURCE.
#
# Everything here is a property of what the new code DOES NOT CONTAIN, which
# is the only way "the packager reaches no network" and "no environment
# variable can redirect an SDK root" are facts rather than sentences:
#
#   - pwebsdk and pweb.cli.sdkmanifest name no URL, link no HTTP client, and
#     name no process API by any of the thirteen swept spellings;
#   - neither of them - nor any unit under tools/pweb - reads an environment
#     variable, and PWEB_SDK / PWEB_HOME / PWEB_MORMOT / PWEB_TEMPLATES
#     appear nowhere except in the prose that says they do not exist;
#   - the SDK layer stays BELOW the build layer: pweb.cli.sdkmanifest is read
#     by the DOCTOR, so a dependency on the pipeline, the process engine or
#     the toolset would put the whole build layer under a diagnostic;
#   - CAP-10D2 adds NO public command and NO public option;
#   - the ratified licence table in pwebsdk equals the machine-readable
#     shipped table in docs/third-party-licenses.md;
#   - the six locks the manifest digests are the six the repository carries;
#   - the shipped paths are CLEAN in git - the dirty-tree refusal PK2 names,
#     performed where every other git-dependent check in this repository
#     lives.
#
# Checkout-only: no toolchain, no network, no display.
#
# Emits build/cap10d2/contracts.json and exits nonzero on any violation.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
$facts = [ordered]@{}
function Violation([string]$Text) {
    $violations.Add($Text)
    Write-Host "VIOLATION: $Text"
}
function Read-Src([string]$Rel) {
    $p = Join-Path $repoRoot $Rel
    if (-not (Test-Path -LiteralPath $p)) {
        Violation "missing source: $Rel"
        return ''
    }
    return [System.IO.File]::ReadAllText($p)
}
# EVERY SWEEP BELOW IS OVER CODE, NOT PROSE. These unit headers explain at
# length why there is no URL and no environment root, and a line-prefix test
# calls the third line of a `{ ... }` block code. So comments are removed
# properly - `{}`, `(* *)` and `//` - and the needle is looked for in what
# is left. A stripper that got this wrong in either direction would make the
# sweep either vacuous or unsatisfiable.
function Strip-Comments([string]$Text) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    $n = $Text.Length
    $inBrace = $false
    $inParen = $false
    $inLine = $false
    $inStr = $false
    while ($i -lt $n) {
        $c = $Text[$i]
        $d = if ($i + 1 -lt $n) { $Text[$i + 1] } else { [char]0 }
        if ($inLine) {
            if ($c -eq "`n") { $inLine = $false; [void]$sb.Append($c) }
            $i++; continue
        }
        if ($inBrace) {
            if ($c -eq '}') { $inBrace = $false }
            elseif ($c -eq "`n") { [void]$sb.Append($c) }
            $i++; continue
        }
        if ($inParen) {
            if (($c -eq '*') -and ($d -eq ')')) { $inParen = $false; $i += 2; continue }
            if ($c -eq "`n") { [void]$sb.Append($c) }
            $i++; continue
        }
        if ($inStr) {
            [void]$sb.Append($c)
            if ($c -eq "'") { $inStr = $false }
            $i++; continue
        }
        if ($c -eq "'") { $inStr = $true; [void]$sb.Append($c); $i++; continue }
        if ($c -eq '{') { $inBrace = $true; $i++; continue }
        if (($c -eq '(') -and ($d -eq '*')) { $inParen = $true; $i += 2; continue }
        if (($c -eq '/') -and ($d -eq '/')) { $inLine = $true; $i += 2; continue }
        [void]$sb.Append($c)
        $i++
    }
    return $sb.ToString()
}

$manifestUnit = Read-Src 'tools/pweb/pweb.cli.sdkmanifest.pas'
$packager = Read-Src 'tools/pweb/pwebsdk.pas'

# --- 1. no network, anywhere on the packaging or verification path ----------
# The needles are CONCATENATED so this file cannot satisfy its own sweep -
# the CAP-10D1 discipline, applied to a new pair of units.
$netNeedles = @(
    ('mormot' + '.net.'), ('THttp' + 'Client'), ('IWinHttp' + 'Api'),
    ('Invoke-' + 'WebRequest'), ('http' + '://'), ('https' + '://'),
    ('ftp' + '://'), ('TCrt' + 'Socket'), ('Win' + 'Http'),
    ('Download' + 'File'), ('TSimple' + 'HttpClient'))
$manifestCode = Strip-Comments $manifestUnit
$packagerCode = Strip-Comments $packager
# CASE-SENSITIVE, and that is not fussiness: `WebClient` matched
# `PWebCliEntry` case-insensitively, which would have made this sweep
# unsatisfiable by the very primitive both units are built on
foreach ($pair in @(@('pweb.cli.sdkmanifest.pas', $manifestCode),
                    @('pwebsdk.pas', $packagerCode))) {
    foreach ($needle in $netNeedles) {
        if ($pair[1] -cmatch [regex]::Escape($needle)) {
            Violation "$($pair[0]) names '$needle' in code"
        }
    }
}
$facts['network_spellings_swept'] = $netNeedles.Count

# --- 2. no process, no shell: a trusted build tool spawns nothing -----------
$procNeedles = @(
    ('Create' + 'Process'), ('fp' + 'Execv'), ('fp' + 'Fork'),
    ('Exec' + 'uteProcess'), ('TPro' + 'cess'), ('Run' + 'Command'),
    ('Run' + 'Redirect'), ('pop' + 'en'), ('sys' + 'tem('),
    ('Shell' + 'Execute'), ('PWebCli' + 'Execute'), ('PWebCli' + 'ChildSpawn'),
    ('PWebCli' + 'RunProbe'))
foreach ($needle in $procNeedles) {
    if ($packagerCode -cmatch [regex]::Escape($needle)) {
        Violation "pwebsdk.pas names the process API '$needle'"
    }
    if ($manifestCode -cmatch [regex]::Escape($needle)) {
        Violation "pweb.cli.sdkmanifest.pas names the process API '$needle'"
    }
}
$facts['process_spellings_swept'] = $procNeedles.Count

# --- 3. no environment-based SDK root, still --------------------------------
# The four names appear ONLY inside comments, where they say they do not
# exist. A code line naming one is the defect this sweeps for.
# The two NEW units read no environment variable at all - not PATH, not TERM,
# nothing. (pweb.cli.platform legitimately reads PATH and TERM: that is the
# CAP-10A executable resolution and the ANSI decision, and neither decides
# where an SDK is.)
$envNeedles = @(('Get' + 'EnvironmentVariable'), ('Get' + 'Env('),
    ('get' + 'env'), ('Sys' + 'Utils.GetEnv'))
$codeEnvHits = 0
foreach ($pair in @(@('pweb.cli.sdkmanifest.pas', $manifestCode),
                    @('pwebsdk.pas', $packagerCode))) {
    foreach ($needle in $envNeedles) {
        if ($pair[1] -cmatch [regex]::Escape($needle)) {
            $codeEnvHits++
            Violation "$($pair[0]) reads an environment variable ('$needle')"
        }
    }
}
# and NO unit under tools/pweb names one of the four root variables in CODE.
# PWEB_SDK_* are the SDK LAYOUT constants and are not environment names, so
# the pattern requires the bare spelling.
$rootNames = @('PWEB_SDK', 'PWEB_HOME', 'PWEB_MORMOT', 'PWEB_TEMPLATES')
foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tools/pweb') `
        -Filter '*.pas' -File)) {
    $code = Strip-Comments ([System.IO.File]::ReadAllText($f.FullName))
    foreach ($name in $rootNames) {
        if ($code -cmatch ("(?<![A-Za-z0-9_])" + $name + "(?![A-Za-z0-9_])")) {
            $codeEnvHits++
            Violation "$($f.Name) names the env root '$name' in code"
        }
    }
}
$facts['env_root_code_hits'] = $codeEnvHits

# --- 4. layering: the SDK layer stays below the build layer -----------------
$usesBlock = ''
if ($manifestUnit -match '(?s)interface\s*\r?\n\s*uses(.*?);') {
    $usesBlock = $Matches[1]
}
$facts['sdkmanifest_uses'] = (($usesBlock -split '[,\r\n]') |
    ForEach-Object { $_.Trim() } | Where-Object { $_ } ) -join ','
foreach ($forbidden in 'pweb.cli.pipeline', 'pweb.cli.process',
                       'pweb.cli.toolset', 'pweb.cli.doctor',
                       'pweb.cli.package', 'pweb.cli.run',
                       'pweb.cli.project') {
    if ($usesBlock -match [regex]::Escape($forbidden)) {
        Violation ("pweb.cli.sdkmanifest uses $forbidden -- the unit the " +
            'DOCTOR reads must stay below the build layer')
    }
}

# --- 5. no public command, no public option ---------------------------------
$args_ = Read-Src 'tools/pweb/pweb.cli.args.pas'
$pwebMain = Read-Src 'tools/pweb/pweb.pas'
foreach ($m in [regex]::Matches($args_, "PWEB_CLI_CMD_[A-Z]+\s*=\s*'([a-z]+)'")) {
    $null = $m
}
$commands = @()
foreach ($m in [regex]::Matches($args_, "'(create|doctor|run|dev|build|sdk|package|install)'")) {
    if ($commands -notcontains $m.Groups[1].Value) { $commands += $m.Groups[1].Value }
}
$facts['advertised_commands'] = ($commands | Sort-Object) -join ','
foreach ($forbidden in 'sdk', 'package', 'install') {
    if ($commands -contains $forbidden) {
        Violation "pweb.cli.args names a '$forbidden' command -- CAP-10D2 adds no public command"
    }
}
if ($pwebMain -match "(?m)^\s+pweb sdk\b") {
    Violation 'pweb.pas usage text advertises `pweb sdk`'
}
# the packager is PRIVATE: it is a PROGRAM, so it cannot be a unit of the
# CLI, and the CLI's own uses clause must not name it. Case-SENSITIVE and
# whole-word: `PWebSdkRefusalTextM` is an ordinary function of the manifest
# unit and matching it would make this check unsatisfiable.
$pwebMainCode = Strip-Comments $pwebMain
if ($pwebMainCode -cmatch '(?<![A-Za-z0-9_.])pwebsdk(?![A-Za-z0-9_])') {
    Violation 'tools/pweb/pweb.pas links the private SDK packager'
}

# --- 6. the licence table equals the documented shipped subset --------------
$licDoc = Read-Src 'docs/third-party-licenses.md'
$docRows = @()
foreach ($line in ($licDoc -split "`r?`n")) {
    if ($line -match '^\|\s*`([A-Za-z0-9._-]+)`\s*\|\s*([a-z0-9_, -]+?)\s*\|') {
        $docRows += [pscustomobject]@{ Name = $Matches[1]; Targets = $Matches[2].Trim() }
    }
}
$facts['documented_licences'] = (($docRows | ForEach-Object { $_.Name }) |
    Sort-Object) -join ','
if ($docRows.Count -eq 0) {
    Violation 'docs/third-party-licenses.md carries no machine-readable shipped table'
}
$tableRows = @()
foreach ($m in [regex]::Matches($packager,
    "\(Path:\s*'(LICENSE\.[A-Za-z0-9._-]+)';\s*Kind:\s*skFile;\s*When_:\s*(sw[A-Za-z]+)")) {
    $tableRows += [pscustomobject]@{ Name = $m.Groups[1].Value; When = $m.Groups[2].Value }
}
$facts['packager_licences'] = (($tableRows | ForEach-Object { $_.Name }) |
    Sort-Object) -join ','
if ($facts['packager_licences'] -cne $facts['documented_licences']) {
    Violation ('the packager licence table and docs/third-party-licenses.md ' +
        "disagree: [$($facts['packager_licences'])] vs [$($facts['documented_licences'])]")
}
# and the CONDITIONS agree row by row: `all` is swAlways, `not macos` is
# swNotMacos, a single target is its own
$whenOf = @{ 'swAlways' = 'all'; 'swWindows' = 'windows-x86_64';
             'swNotMacos' = 'not macos' }
foreach ($t in $tableRows) {
    $d = $docRows | Where-Object { $_.Name -ceq $t.Name }
    if ($null -eq $d) { continue }
    if ($whenOf[$t.When] -cne $d.Targets) {
        Violation ("licence condition drift for $($t.Name): packager says " +
            "$($t.When) ($($whenOf[$t.When])), the document says '$($d.Targets)'")
    }
}

# --- 7. the six locks -------------------------------------------------------
$declared = @()
if ($manifestUnit -match "(?s)PWEB_SDK_LOCKS:.*?\((.*?)\);") {
    foreach ($m in [regex]::Matches($Matches[1], "'([a-z0-9.-]+\.lock)'")) {
        $declared += $m.Groups[1].Value
    }
}
$onDisk = @(Get-ChildItem -LiteralPath $repoRoot -Filter '*.lock' -File |
    ForEach-Object { $_.Name } | Sort-Object)
$facts['locks_declared'] = ($declared | Sort-Object) -join ','
$facts['locks_on_disk'] = $onDisk -join ','
if ((($declared | Sort-Object) -join ',') -cne ($onDisk -join ',')) {
    Violation ("the manifest's lock list [$($facts['locks_declared'])] is not " +
        "the repository's [$($facts['locks_on_disk'])]")
}

# --- 8. the shipped paths are clean in git ----------------------------------
# The dirty-tree refusal PK2 names, performed where every other git-dependent
# check in this repository lives: a Pascal build tool spawns nothing, so it
# cannot ask git anything, and a packager that took a `--dirty` flag would be
# taking somebody's word for it.
$shipped = @('src', 'sdk/typescript/src', 'sdk/pas2js', 'tools/templates',
    'tools/pweb', 'tools/setup')
$dirty = @()
try {
    $status = & git -C $repoRoot status --porcelain -- @shipped 2>&1
    if ($LASTEXITCODE -eq 0) {
        $dirty = @($status | Where-Object { $_ -and ($_ -notmatch '^\?\? ') })
    } else {
        $dirty = @('<git unavailable>')
    }
} catch {
    $dirty = @('<git unavailable>')
}
$facts['shipped_tree_dirty'] = $dirty.Count
foreach ($d in $dirty) {
    Violation "a shipped path is modified in the working tree: $d"
}

# --- 9. the pipeline still has ten stages and one engine caller set ---------
$pipeline = Read-Src 'tools/pweb/pweb.cli.pipeline.pas'
$stageCount = 0
if ($pipeline -match "(?s)TPWebCliStageKind = \((.*?)\);") {
    $stageCount = @([regex]::Matches($Matches[1], 'psk[A-Za-z]+')).Count
}
$facts['build_stage_count'] = $stageCount
if ($stageCount -ne 10) {
    Violation "the pipeline declares $stageCount stages; ten are frozen"
}
# pweb.cli.process DEFINES the engine and is excluded, exactly as
# check_cap10d1_contracts.ps1 excludes it: the invariant is the enumerated
# set of CALLERS, and the engine is not one of them.
$callers = @()
foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tools/pweb') `
        -Filter '*.pas' -File)) {
    if ($f.Name -eq 'pweb.cli.process.pas') { continue }
    $code = Strip-Comments ([System.IO.File]::ReadAllText($f.FullName))
    if ($code -match 'PWebCliExecute\s*\(') {
        if ($callers -notcontains $f.BaseName) { $callers += $f.BaseName }
    }
}
$facts['build_execute_callers'] = ($callers | Sort-Object) -join ','
$facts['build_execute_caller_count'] = $callers.Count
if ($callers.Count -ne 5) {
    Violation ("$($callers.Count) units call PWebCliExecute " +
        "[$($facts['build_execute_callers'])]; the enumerated set is five")
}

# --- 10. the SDK-shipped tool rule, at the source ---------------------------
# ONE rule, no fallback chain: a tool is EITHER resolved from the SDK root or
# from PATH, and no tool is in both columns. `pwebbundle` and the Inno Setup
# compiler are resolved by walking the SDK root; fpc, node and pas2js are
# resolved on PATH by the CAP-10A rule. The measurement is that the units
# that walk the SDK never call the PATH resolver for those two names, and
# that the PATH resolver is never handed a name the SDK ships.
$sdkroot = Read-Src 'tools/pweb/pweb.cli.sdkroot.pas'
$package = Read-Src 'tools/pweb/pweb.cli.package.pas'
foreach ($pair in @(@('pweb.cli.sdkroot.pas', (Strip-Comments $sdkroot)),
                    @('pweb.cli.package.pas', (Strip-Comments $package)))) {
    if ($pair[1] -match 'PWebCliFindExecutable|PWebCliPathDirs') {
        Violation "$($pair[0]) resolves an SDK-shipped tool through PATH"
    }
}
$toolset = Strip-Comments (Read-Src 'tools/pweb/pweb.cli.toolset.pas')
foreach ($shipped in 'pwebbundle', 'ISCC') {
    if ($toolset -cmatch "'$shipped'") {
        Violation "pweb.cli.toolset (the PATH resolver) names the SDK-shipped tool '$shipped'"
    }
}
$facts['sdk_shipped_tool_rule'] =
    'sdk_root_only:pwebbundle,iscc|path_only:fpc,node,pas2js'

# --- verdict -----------------------------------------------------------------
New-Item -ItemType Directory -Force (Join-Path $repoRoot 'build/cap10d2') | Out-Null
$facts['violations'] = $violations.Count
$facts['verdict'] = if ($violations.Count -eq 0) { 'PASS' } else { 'FAIL' }
[System.IO.File]::WriteAllText(
    (Join-Path $repoRoot 'build/cap10d2/contracts.json'),
    (($facts | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host ($facts | ConvertTo-Json -Depth 6)
if ($violations.Count -gt 0) {
    throw "CAP-10D2 contract cross-checks FAILED: $($violations.Count) violation(s)"
}
Write-Host '[CAP-10D2] contract cross-checks PASS'
