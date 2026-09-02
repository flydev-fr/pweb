# CAP-10B1 contract cross-checks. Checkout-plus-build only: no toolchain, no
# network, no window - it runs in every platform job and on any dev host.
#
# SEVEN THINGS ARE CHECKED, and each is a claim CAP-10B1 makes that would
# otherwise be a comment:
#
#   1. THE ADVERTISED UIs ARE THE COMPILED ONES, EACH SPELLED ONCE. The
#      parser carries a compiled allowlist and the help text INTERPOLATES
#      it. A build that advertised a frontend it has no template for would
#      be promising a scaffold it cannot produce, which is exactly what
#      CAP-10A refused to do with `create` itself.
#
#      CAP-10B2 INVERTED THIS RULE RATHER THAN DELETING IT. CAP-10B1
#      required that no source anywhere accept `pas2js`; the same
#      measurement now has to come out the other way, because the template
#      that makes the claim true shipped. What did NOT change is the shape:
#      the allowlist is still compiled, still spelled once per kind, and the
#      help still cannot carry its own copy of the answer. The Pas2JS
#      template's own rules live in test/cap10b2.
#
#   2. `dev`, `run` AND `build` ARE STILL UNKNOWN COMMANDS. Not stubs, not
#      "not implemented" placeholders, and not in any help text.
#
#   3. THE CREATE PATH EXECUTES NOTHING. `pweb create` may not reach the
#      probe layer, the toolchain layer, a process API, a shell or the
#      environment. Creation writes files; it does not fetch, install or
#      build, and there must be no code path through which it could.
#
#   4. THE TEMPLATE SOURCE IS FULLY TRACKED, LF AND CLEAN. Both directions:
#      a file on disk that git does not track, and a tracked file that is
#      not on disk, are each an error. No CR, no host path, no secret name.
#
#   5. THE PINS ARE SINGLE-SOURCE. Every version in the generated
#      package.json is exact - no caret, no tilde, no range, no `latest` -
#      and every one of them matches the table in docs/template-contract.md.
#      A pin that lives in two places is a pin that will one day be two.
#
#   6. THE GENERATED PASCAL CARRIES NO PLATFORM CONDITIONAL. That is the
#      whole point of the reusable host unit: an application should not have
#      to know which WebView it is running on.
#
#   7. THE DOCUMENTED SURFACE IS THE COMPILED SURFACE. The create grammar,
#      the exit mapping and the supported UI in docs/cli-contract.md and
#      docs/template-contract.md are cross-checked against the source, so a
#      contract nobody cross-checks cannot drift into fiction.
#
# Emits build/cap10b1/contracts.json, which the gates fold into the corpus.
#
# Usage: pwsh test/cap10b1/check_cap10b1_contracts.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
function Violation([string]$Text) { $violations.Add($Text) }

# Pascal with comments removed, so a rule about CODE is never satisfied or
# broken by prose. The three comment forms, and nesting, exactly as the
# CAP-10B0 check does it.
function Get-CodeLines([string]$Path) {
    $out = New-Object System.Collections.Generic.List[object]
    $lines = [System.IO.File]::ReadAllLines($Path)
    $inBrace = $false
    $inParen = $false
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        $kept = ''
        $j = 0
        while ($j -lt $line.Length) {
            if ($inBrace) {
                if ($line[$j] -eq '}') { $inBrace = $false }
                $j++
                continue
            }
            if ($inParen) {
                if (($line[$j] -eq '*') -and ($j + 1 -lt $line.Length) -and
                    ($line[$j + 1] -eq ')')) { $inParen = $false; $j += 2; continue }
                $j++
                continue
            }
            if ($line[$j] -eq '{') { $inBrace = $true; $j++; continue }
            if (($line[$j] -eq '(') -and ($j + 1 -lt $line.Length) -and
                ($line[$j + 1] -eq '*')) { $inParen = $true; $j += 2; continue }
            if (($line[$j] -eq '/') -and ($j + 1 -lt $line.Length) -and
                ($line[$j + 1] -eq '/')) { break }
            $kept += $line[$j]
            $j++
        }
        if ($kept.Trim() -ne '') {
            $out.Add([pscustomobject]@{ Number = $i + 1; Text = $kept })
        }
    }
    return $out
}

$templateRoot = 'tools/templates/react'
foreach ($p in 'tools/pweb/pweb.cli.args.pas', 'tools/pweb/pweb.cli.report.pas',
                'tools/pweb/pweb.pas', 'tools/templates/templates.list',
                "$templateRoot/src/program.lpr",
                "$templateRoot/src/app.services.pas",
                "$templateRoot/frontend/package.json",
                "$templateRoot/frontend/package-lock.json",
                'src/webview/pweb.webview.host.pas',
                'docs/cli-contract.md', 'docs/template-contract.md') {
    if (-not (Test-Path $p)) { throw "missing CAP-10B1 source: $p" }
}

$argsSource = [System.IO.File]::ReadAllText('tools/pweb/pweb.cli.args.pas')
$reportSource = [System.IO.File]::ReadAllText('tools/pweb/pweb.cli.report.pas')
$programSource = [System.IO.File]::ReadAllText('tools/pweb/pweb.pas')

# --- 1. the two UIs, each spelled ONCE ------------------------------------
$uiConsts = [ordered]@{ PWEB_CLI_UI_REACT = 'react'; PWEB_CLI_UI_PAS2JS = 'pas2js' }
$advertised = New-Object System.Collections.Generic.List[string]
foreach ($name in $uiConsts.Keys) {
    $m = [regex]::Match($argsSource, "$name\s*=\s*'([a-z0-9]+)'")
    if (-not $m.Success) {
        Violation "pweb.cli.args.pas declares no $name allowlist constant"
    } elseif ($m.Groups[1].Value -cne $uiConsts[$name]) {
        Violation ("$name is '$($m.Groups[1].Value)', expected " +
            "'$($uiConsts[$name])'")
    } else {
        $advertised.Add($m.Groups[1].Value)
    }
}
# ONE canonical order, bytewise, so the fact travels the same way on every
# target and through every gate that carries it
$advertisedUi = (($advertised.ToArray() | Sort-Object -CaseSensitive) -join ',')
# the help text must INTERPOLATE both constants, never restate them: a
# second spelling is a second contract
if ($reportSource -notmatch
    'This build supports: ''\s*\+\s*PWEB_CLI_UI_REACT\s*\+\s*''\|''\s*\+\s*PWEB_CLI_UI_PAS2JS') {
    Violation ('pweb.cli.report.pas does not interpolate BOTH UI constants ' +
        'into the create help - a help text with its own copy of the ' +
        'answer can advertise a frontend the parser refuses')
}
# and the allowlist that decides it must name both, in CODE
$allowlistNames = 0
foreach ($row in (Get-CodeLines 'tools/pweb/pweb.cli.args.pas')) {
    if ($row.Text -match 'Result\.Ui\s*<>\s*PWEB_CLI_UI_(REACT|PAS2JS)') {
        $allowlistNames++
    }
    # the kinds are named by their CONSTANTS everywhere except the two
    # declarations - a bare literal in the parser is the second spelling
    # this rule exists to prevent
    if (($row.Text -match "'(react|pas2js)'") -and
        ($row.Text -notmatch 'PWEB_CLI_UI_(REACT|PAS2JS)\s*=')) {
        Violation ("pweb.cli.args.pas spells a frontend kind as a bare " +
            "literal at line $($row.Number): $($row.Text.Trim())")
    }
}
if ($allowlistNames -ne 2) {
    Violation ("the create allowlist tests $allowlistNames UI constant(s), " +
        'expected exactly 2 (react and pas2js)')
}
foreach ($doc in 'docs/cli-contract.md', 'docs/template-contract.md') {
    $text = [System.IO.File]::ReadAllText($doc)
    if (-not $text.Contains('--ui react|pas2js')) {
        Violation "$doc does not document the create grammar --ui react|pas2js"
    }
}

# --- 2. dev and build are still unknown commands ---------------------------
# (CAP-10C0 exposed `run`; the CAP-10C0 gates measure that surface)
foreach ($cmd in 'dev', 'build') {
    if ($argsSource -match "pccC?$cmd\b") {
        Violation "pweb.cli.args.pas defines a '$cmd' command"
    }
    if ($reportSource -match "pweb $cmd ") {
        Violation "pweb.cli.report.pas advertises 'pweb $cmd'"
    }
}
if ($argsSource -notmatch 'pccCreate\b') {
    Violation "pweb.cli.args.pas defines no 'create' command"
}

# --- 3. the create path executes nothing ---------------------------------
# The create runner is extracted by name and swept: the units it may reach
# are the engine and the report layer, and nothing that starts a process or
# reads the environment. The doctor path keeps its bounded probe; create
# must have no path to one at all.
$createBody = [regex]::Match($programSource,
    '(?s)function RunCreate\(.*?\n(end;)').Value
if ($createBody -eq '') {
    Violation 'tools/pweb/pweb.pas has no RunCreate function to sweep'
}
$processApis = 'PWebCliProbe|PWebCliRealEnv|PWebCliToolchain|GetEnvironment' +
    'Variable|getenv|CreateProcess|ShellExecute|fpExecv|fpSystem|popen|' +
    'RunRedirect|RunCommand|TProcess'
foreach ($m in [regex]::Matches($createBody, $processApis)) {
    Violation ("the create path names a process or environment API: " +
        $m.Value)
}
$createApis = 0
foreach ($m in [regex]::Matches($createBody,
        'PWebCliTemplatePack|PWebTplLoadPack|PWebTplVerifyPack|PWebBuildPlan|PWebCreateProject')) {
    $createApis++
}
if ($createApis -lt 5) {
    Violation ("the create path does not call the frozen engine end to end " +
        "(found $createApis of the 5 named entry points) -- a dispatch " +
        'layer that renders or writes for itself is a second engine')
}

# --- 4. the template source is tracked, LF and clean ---------------------
$tracked = @(& git ls-files $templateRoot) | Where-Object { $_ -ne '' }
$onDisk = @(Get-ChildItem $templateRoot -Recurse -File -Force |
    ForEach-Object {
        ($_.FullName.Substring($repoRoot.Length + 1) -replace '\\', '/')
    })
foreach ($f in $onDisk) {
    if ($tracked -notcontains $f) {
        Violation "untracked file in the trusted template source: $f"
    }
}
foreach ($f in $tracked) {
    if ($onDisk -notcontains $f) {
        Violation "tracked template source is not on disk: $f"
    }
}
$crFiles = 0
$secretNames = 0
foreach ($f in $onDisk) {
    $bytes = [System.IO.File]::ReadAllBytes($f)
    if ($bytes -contains 13) {
        $crFiles++
        Violation "the template source carries a CR byte: $f"
    }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    foreach ($needle in '/Users/', '/home/', '\Users\', '%USERPROFILE%',
                        '/private/var/folders/') {
        if ($text.Contains($needle)) {
            Violation "the template source carries a host path: $f ($needle)"
        }
    }
    $leaf = [System.IO.Path]::GetFileName($f)
    if ($leaf -match '^\.env|\.(pem|key|p12|pfx|crt|cer|db|sqlite3?)$') {
        $secretNames++
        Violation "the template source carries a credential-shaped name: $f"
    }
}
# the .gitattributes pin exists BECAUSE of the CR rule above: Git for
# Windows defaults to core.autocrlf=true, and a CRLF checkout does not
# merely diverge here, it fails the pack build
$attrs = [System.IO.File]::ReadAllText('.gitattributes')
foreach ($ext in 'ts', 'tsx') {
    if ($attrs -notmatch [regex]::Escape("tools/templates/**/*.$ext text eol=lf")) {
        Violation ".gitattributes does not pin tools/templates/**/*.$ext to LF"
    }
}

# --- 5. the pins are exact and single-source -----------------------------
$pkg = Get-Content -Raw "$templateRoot/frontend/package.json" | ConvertFrom-Json
$pins = [ordered]@{}
foreach ($section in 'dependencies', 'devDependencies') {
    foreach ($p in $pkg.$section.PSObject.Properties) {
        $pins[$p.Name] = $p.Value
    }
}
foreach ($name in $pins.Keys) {
    $v = "$($pins[$name])"
    if ($name -eq '@pweb/runtime') {
        # the ONE dependency that is not a version: it is a project-relative
        # file: specifier, resolved from the trusted SDK root at build time
        if ($v -cne 'file:.pweb/sdk/typescript') {
            Violation "@pweb/runtime is '$v', expected file:.pweb/sdk/typescript"
        }
        continue
    }
    if ($v -notmatch '^\d+\.\d+\.\d+$') {
        Violation ("the pin for $name is '$v' -- exact X.Y.Z only, no " +
            'caret, tilde, range or latest')
    }
}
$contractDoc = [System.IO.File]::ReadAllText('docs/template-contract.md')
foreach ($name in $pins.Keys) {
    if ($name -eq '@pweb/runtime') { continue }
    $v = "$($pins[$name])"
    if ($contractDoc -notmatch ("(?m)\|\s*``" + [regex]::Escape($name) +
            "``\s*\|\s*``" + [regex]::Escape($v) + "``\s*\|")) {
        Violation ("docs/template-contract.md does not record the pin " +
            "$name = $v")
    }
}
# and the lockfile agrees with the manifest about the root identity
$lock = [System.IO.File]::ReadAllText("$templateRoot/frontend/package-lock.json")
if ($lock -notmatch '"lockfileVersion":\s*3') {
    Violation 'the template lockfile is not lockfileVersion 3'
}
# `file:` and `node_modules/` are legitimate INSIDE the lock - the first is
# the SDK specifier and the second is how npm keys its package map - so what
# is refused here is an ABSOLUTE file URL and a plain-http registry, never
# the strings themselves
if ($lock -match 'file:///' -or $lock -match '"resolved":\s*"file:[A-Za-z]:') {
    Violation 'the template lockfile carries an absolute file URL'
}
if ($lock -match '"resolved":\s*"http://') {
    Violation 'the template lockfile resolves a package over plain http'
}

# --- 6. the generated Pascal carries no platform conditional -------------
$platformRx = '\{\$\s*(?:ifdef|ifndef|elseif|if|else|endif)\b[^}]*\}'
$platformSym = '\b(WIN32|WIN64|WINDOWS|OSWINDOWS|MSWINDOWS|LINUX|DARWIN|UNIX|' +
    'POSIX|BSD|IOS|OSX|MACOS|ANDROID|CPUX86_64|CPUX64|CPUAARCH64|CPUARM64|' +
    'AARCH64|CPU32|CPU64)\b'
$generatedConditionals = 0
foreach ($f in "$templateRoot/src/program.lpr", "$templateRoot/src/app.services.pas") {
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($f)) {
        $lineNo++
        foreach ($m in [regex]::Matches($line, $platformRx)) {
            if ($m.Value -match $platformSym) {
                # {$apptype console} needs OSWINDOWS and is the ONE allowed
                # conditional: it selects a SUBSYSTEM, not a behaviour, and
                # the generated README says how to remove it
                if ($m.Value -notmatch 'OSWINDOWS') {
                    $generatedConditionals++
                    Violation ("the generated Pascal carries a platform " +
                        "conditional: ${f}:${lineNo}: $($m.Value)")
                }
            }
        }
    }
}

# --- 6b. what the generated application may and may not be ---------------
#
# Three properties of the generated Pascal that a runtime gate can only
# observe by running, and that a source rule can refuse before anything is
# built. Each of them is an adversarial question this shard was asked:
#
#   can generated code use an allow-all policy?   it must name an explicit
#                                                 AppMaximum and must not
#                                                 name the allow-all class;
#   can it open a listener?                       it must name no HTTP
#                                                 server unit and no
#                                                 listening API;
#   can it enable QuickJS by default?             it must name no script
#                                                 unit at all.
$appServices = [System.IO.File]::ReadAllText("$templateRoot/src/app.services.pas")
$appProgram = [System.IO.File]::ReadAllText("$templateRoot/src/program.lpr")
$generatedPascal = $appServices + "`n" + $appProgram
if ($appServices -notmatch 'SetAppMaximum\(\[') {
    Violation ('the generated policy does not set an explicit AppMaximum -- ' +
        'no AppMaximum means no capabilities, and an implicit one would ' +
        'mean nobody stated the ceiling')
}
foreach ($banned in 'TAllowAllCapabilityPolicy', 'AllowAll') {
    if ($generatedPascal -match [regex]::Escape($banned)) {
        Violation "the generated application names $banned"
    }
}
foreach ($banned in 'mormot.rest.http', 'TRestHttpServer', 'mormot.net.',
                    'TCrtSocket', 'bind(', 'listen(') {
    if ($generatedPascal -match [regex]::Escape($banned)) {
        Violation ("the generated application names a listening transport: " +
            $banned)
    }
}
foreach ($banned in 'pweb.script.', 'quickjs', 'QuickJS') {
    if ($generatedPascal -match [regex]::Escape($banned)) {
        Violation "the generated application enables a script runtime: $banned"
    }
}
# and the runtime-command layer IS installed, while the capability that
# would authorize it is NOT granted - which is the whole of "defence in
# depth" stated as two rules rather than one comment
if ($appProgram -notmatch 'PWebHostRuntimeBridge') {
    Violation ('the generated application does not install the reusable ' +
        'runtime-command layer')
}
if ($appServices -match 'external\.open') {
    Violation ('the generated policy grants external.open -- the sample ' +
        'application opens no link, so nothing should authorize it to')
}

# --- 6c. the lockfile's install scripts are the reviewed ones ------------
#
# npm runs a package's install script with the developer's privileges, so
# the SET of packages that have one is part of this template's contract.
# `fsevents` is the only member: it is macOS-only, optional, and reached
# through the watcher Vite ships. It is named here so that a NEW one cannot
# arrive unnoticed with a routine pin bump.
# -AsHashtable: a lockfile's package map is keyed by path and the ROOT
# package's key is the empty string, which ConvertFrom-Json cannot express
# as a property name
$lockDoc = Get-Content -Raw "$templateRoot/frontend/package-lock.json" |
    ConvertFrom-Json -AsHashtable
$installScripts = @()
foreach ($k in $lockDoc.packages.Keys) {
    if ($lockDoc.packages[$k].hasInstallScript -eq $true) {
        $installScripts += ($k -replace '^node_modules/', '')
    }
}
$installScripts = @($installScripts | Sort-Object)
$reviewedInstallScripts = @('fsevents')
if ((($installScripts -join '|')) -cne (($reviewedInstallScripts -join '|'))) {
    Violation ("the template lockfile's install-script set is " +
        "'$($installScripts -join ', ')', reviewed: " +
        "'$($reviewedInstallScripts -join ', ')'")
}
# and no PWeb-owned lifecycle script: the generated package.json declares
# exactly two scripts, neither of which npm runs on its own
$scriptNames = @($pkg.scripts.PSObject.Properties.Name) | Sort-Object
$expectedScripts = @('build', 'typecheck') | Sort-Object
if ((($scriptNames -join '|')) -cne (($expectedScripts -join '|'))) {
    Violation ("the generated package.json declares scripts " +
        "'$($scriptNames -join ', ')', expected 'build, typecheck' -- a " +
        'lifecycle script would run without anyone asking for it')
}
# @pweb/runtime is LINKED, never fetched: the lock must mark it so, and its
# target must be relative
$runtimeEntry = $lockDoc.packages['node_modules/@pweb/runtime']
if ($null -eq $runtimeEntry) {
    Violation 'the template lockfile has no node_modules/@pweb/runtime entry'
} else {
    if ($runtimeEntry.link -ne $true) {
        Violation ('the lockfile does not mark @pweb/runtime as a link -- ' +
            'anything else means a registry could answer for that name')
    }
    if ("$($runtimeEntry.resolved)" -cne '.pweb/sdk/typescript') {
        Violation ("@pweb/runtime resolves to '$($runtimeEntry.resolved)', " +
            'expected the project-relative .pweb/sdk/typescript')
    }
}

# --- 7. the documented surface is the compiled surface -------------------
$cliDoc = [System.IO.File]::ReadAllText('docs/cli-contract.md')
foreach ($phrase in 'pweb create NAME --ui react|pas2js --bundle-id',
                    'pweb create --help') {
    if (-not $cliDoc.Contains($phrase)) {
        Violation "docs/cli-contract.md does not document: $phrase"
    }
}
# the exit mapping, as the command actually implements it
foreach ($pair in @(@('PWEB_EXIT_USAGE', '2'), @('PWEB_EXIT_PROJECT', '3'),
                    @('PWEB_EXIT_ENVIRONMENT', '4'),
                    @('PWEB_EXIT_INTERNAL', '6'))) {
    if ($programSource -notmatch ("$($pair[0])\s*=\s*$($pair[1])\s*;")) {
        Violation "tools/pweb/pweb.pas does not define $($pair[0]) = $($pair[1])"
    }
}
# create can never produce a probe error, because it starts no child
if ($createBody -match 'PWEB_EXIT_PROBE') {
    Violation ('the create path can return exit 5 -- create starts no ' +
        'child process, so there is no probe for one to come from')
}

# --- the evidence this check produces -------------------------------------
New-Item -ItemType Directory -Force build/cap10b1 | Out-Null
$facts = [ordered]@{
    advertised_ui             = $advertisedUi
    template_sources          = $onDisk.Count
    template_cr_files         = $crFiles
    template_secret_names     = $secretNames
    generated_conditionals    = $generatedConditionals
    create_engine_calls       = $createApis
    frontend_pins             = @($pins.Keys).Count
    violations                = $violations.Count
}
[System.IO.File]::WriteAllText('build/cap10b1/contracts.json',
    (($facts | ConvertTo-Json -Depth 4) + "`n"),
    [System.Text.UTF8Encoding]::new($false))

if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Write-Host "CONTRACT VIOLATION: $v" }
    throw "CAP-10B1 contract cross-checks FAILED: $($violations.Count)"
}
Write-Host ("[CAP-10B1] contracts PASS - the advertised UIs are " +
    "$advertisedUi, $($onDisk.Count) tracked react template sources, " +
    "$($generatedConditionals) platform conditionals in the generated " +
    'Pascal, and no process or environment API on the create path')
