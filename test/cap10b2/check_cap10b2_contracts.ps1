# CAP-10B2 contract cross-checks. Checkout-plus-build only: no toolchain, no
# network, no window - it runs in every platform job and on any dev host.
#
# SEVEN THINGS ARE CHECKED, and each is a claim CAP-10B2 makes that would
# otherwise be a comment:
#
#   1. THE ADVERTISED UIs ARE THE SHIPPED TEMPLATES. The parser's two
#      compiled constants, the two PUBLIC template ids and the `ui` each of
#      those templates declares are ONE set, cross-checked three ways. A
#      build that advertises a frontend whose template nobody shipped is
#      exactly what CAP-10A refused to do with `create` itself.
#
#   2. THERE IS ONE GENERATED NATIVE APPLICATION, NOT TWO. src/
#      app.services.pas is BYTE-IDENTICAL between the react and pas2js
#      templates, and src/program.lpr is byte-identical once comments are
#      removed - its only difference is the frontend name in the data-path
#      comment. `.gitattributes` and the stylesheet are byte-identical too.
#      The UI is build content; it is not native behaviour.
#
#   3. THE PAS2JS FRONTEND IS THE CANONICAL ONE. It reaches the backend
#      through the frozen pweb.native SDK, with the same entry points, the
#      same method spelling and the same named arguments as
#      examples/05-pas2js - the CAP-5 application this template is derived
#      from. An unaudited copy is not a derivation.
#
#   4. THE GENERATED APPLICATION OWNS NO RAW BINDING. Neither
#      `__pweb_invoke` nor either platform channel appears anywhere in the
#      pas2js template, and the ONE unit that may name the binding is the
#      SDK. The compiled-bundle half of this rule is a runtime measurement
#      and lives in prove_cap10b2.
#
#   5. A PAS2JS PROJECT NEEDS NO NODE. The template declares no
#      package.json, no lockfile, no tsconfig, no bundler config and no
#      JavaScript at all - so nothing exists here merely to look like the
#      react template.
#
#   6. NEITHER GENERATED PASCAL CARRIES A PLATFORM CONDITIONAL, and neither
#      may be an allow-all policy, open a listener or enable a script
#      runtime. Same rules as CAP-10B1's, applied to this template.
#
#   7. THE DOCUMENTED SURFACE IS THE COMPILED SURFACE. The two-UI grammar,
#      the Pas2JS doctor row and the exact 3.0.1 pin are cross-checked
#      against pas2js.lock and the source.
#
# Emits build/cap10b2/contracts.json, which the gates fold into the corpus.
#
# Usage: pwsh test/cap10b2/check_cap10b2_contracts.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
function Violation([string]$Text) { $violations.Add($Text) }

# Pascal with comments removed, so a rule about CODE is never satisfied or
# broken by prose.
#
# THE PLACEHOLDER SUBSTITUTION IS LOAD-BEARING, and it is the one thing this
# copy does that the CAP-10B0 and CAP-10B1 copies do not need to. A template
# is not Pascal yet: `{ {{PROJECT_NAME}} - a PWeb application.` opens a brace
# comment and then immediately writes `{{`, and the stripper is a FLAG rather
# than a counter (as Pascal's own scanner is - FPC warns "Comment level 2"),
# so `}}` closes the comment 30 lines early and the whole header reads as
# code. MEASURED: without this, the data-path comment is reported as a
# frontend-kind branch in the generated Pascal.
#
# Every token is replaced by one placeholder-free identifier of the same
# shape in BOTH files, so a comparison between them is unaffected.
function Get-CodeLines([string]$Path) {
    $out = New-Object System.Collections.Generic.List[object]
    $lines = ([regex]::Replace(
        [System.IO.File]::ReadAllText($Path),
        '\{\{[A-Z_]+\}\}', 'PWEBTOKEN')) -split "`r?`n"
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
function Sha256File([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Sha256Text([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha.ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($Text)) |
            ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}
function CodeText([string]$Path) {
    return (((Get-CodeLines $Path) | ForEach-Object { $_.Text.TrimEnd() }) -join "`n")
}

$react = 'tools/templates/react'
$p2j = 'tools/templates/pas2js'
foreach ($p in 'tools/pweb/pweb.cli.args.pas', 'tools/pweb/pweb.cli.report.pas',
                'tools/pweb/pweb.pas', 'tools/templates/templates.list',
                'sdk/pas2js/pweb.native.pas',
                'examples/05-pas2js/frontend/src/p2japp.pas',
                'pas2js.lock', 'tools/pweb/pweb.cli.toolchain.pas',
                "$react/src/program.lpr", "$react/src/app.services.pas",
                "$react/gitattributes", "$react/frontend/src/app.css",
                "$p2j/src/program.lpr", "$p2j/src/app.services.pas",
                "$p2j/gitattributes", "$p2j/frontend/app.css",
                "$p2j/frontend/index.html", "$p2j/frontend/pas2js.cfg",
                "$p2j/frontend/src/program.lpr", "$p2j/frontend/src/app.pas",
                "$p2j/README.md", "$p2j/gitignore",
                'docs/cli-contract.md', 'docs/template-contract.md') {
    if (-not (Test-Path $p)) { throw "missing CAP-10B2 source: $p" }
}

$argsSource = [System.IO.File]::ReadAllText('tools/pweb/pweb.cli.args.pas')
$listText = [System.IO.File]::ReadAllText('tools/templates/templates.list')

# --- 1. the advertised UIs ARE the shipped templates ----------------------
$parserUis = @()
foreach ($m in [regex]::Matches($argsSource,
        "PWEB_CLI_UI_[A-Z0-9]+\s*=\s*'([a-z0-9]+)'")) {
    $parserUis += $m.Groups[1].Value
}
$parserUis = @($parserUis | Sort-Object -CaseSensitive -Unique)

# the trusted list, parsed the way the builder parses it: `template` opens a
# block and the keys under it belong to that block
$templates = [ordered]@{}
$current = ''
foreach ($line in [System.IO.File]::ReadAllLines('tools/templates/templates.list')) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    if ($t -match '^template\s*=\s*(\S+)$') {
        $current = $Matches[1]
        $templates[$current] = [ordered]@{}
        continue
    }
    if (($current -ne '') -and ($t -match '^([a-z-]+)\s*=\s*(.+)$')) {
        if (-not $templates[$current].Contains($Matches[1])) {
            $templates[$current][$Matches[1]] = $Matches[2]
        }
    }
}
$publicIds = @($templates.Keys | Where-Object {
    $templates[$_]['visibility'] -ceq 'public' } | Sort-Object -CaseSensitive)
$declaredUis = @($publicIds | ForEach-Object { $templates[$_]['ui'] } |
    Sort-Object -CaseSensitive)
$supportedUis = ($parserUis -join ',')
if ($supportedUis -cne 'pas2js,react') {
    Violation ("the parser's compiled allowlist is '$supportedUis', " +
        "expected 'pas2js,react'")
}
if (($publicIds -join ',') -cne 'pas2js,react') {
    Violation ("the PUBLIC template ids are '$($publicIds -join ',')', " +
        "expected 'pas2js,react' -- the template id IS the --ui value " +
        '(PWebTplFind matches on Id), so a mismatch means a kind the parser ' +
        'accepts has no template to select')
}
if (($declaredUis -join ',') -cne 'pas2js,react') {
    Violation ("the PUBLIC templates declare ui '$($declaredUis -join ',')', " +
        "expected 'pas2js,react'")
}
foreach ($id in $publicIds) {
    if ($templates[$id]['ui'] -cne $id) {
        Violation ("template '$id' declares ui '$($templates[$id]['ui'])' -- " +
            'the id and the ui must be the same string, because create looks ' +
            'the template up BY the --ui value')
    }
}
if ($templates['fixture']['visibility'] -cne 'private') {
    Violation 'the CAP-10B0 fixture is no longer private'
}

# --- 2. ONE generated native application ----------------------------------
$byteIdentical = @(
    @('src/app.services.pas', 'src/app.services.pas'),
    @('gitattributes', 'gitattributes'),
    @('frontend/src/app.css', 'frontend/app.css')
)
$sharedDigests = New-Object System.Collections.Generic.List[string]
foreach ($pair in $byteIdentical) {
    $a = Join-Path $react $pair[0]
    $b = Join-Path $p2j $pair[1]
    $ha = Sha256File $a
    $hb = Sha256File $b
    $sharedDigests.Add("$($pair[1]) $ha")
    if ($ha -cne $hb) {
        Violation ("$($pair[1]) is not byte-identical between the two " +
            "templates ($ha vs $hb) -- there is one application, and a " +
            'file that is allowed to drift is two')
    }
}
# the entry point: identical CODE, and a raw difference confined to the
# header comment. The UI literal is the ONE thing a native source may say
# about its frontend, and it says it where nothing compiles it.
$reactCode = CodeText (Join-Path $react 'src/program.lpr')
$p2jCode = CodeText (Join-Path $p2j 'src/program.lpr')
if ($reactCode -cne $p2jCode) {
    Violation ('src/program.lpr differs between the templates in CODE, not ' +
        'only in comments -- the generated native host must not branch on ' +
        'frontend kind')
}
$sharedNativeDigest = Sha256Text ($p2jCode + "`n")
# and the raw difference is exactly the data-path comment
$reactRaw = [System.IO.File]::ReadAllLines((Join-Path $react 'src/program.lpr'))
$p2jRaw = [System.IO.File]::ReadAllLines((Join-Path $p2j 'src/program.lpr'))
$diffLines = 0
if ($reactRaw.Length -ne $p2jRaw.Length) {
    Violation ('src/program.lpr has a different LINE COUNT between the two ' +
        'templates -- the only permitted difference is the frontend name in ' +
        'the data-path comment')
} else {
    for ($i = 0; $i -lt $reactRaw.Length; $i++) {
        if ($reactRaw[$i] -cne $p2jRaw[$i]) {
            $diffLines++
            if ($p2jRaw[$i] -notmatch '^\s+(Pas2JS|->)') {
                Violation ("src/program.lpr line $($i + 1) differs outside " +
                    "the data-path comment: $($p2jRaw[$i])")
            }
            if ($reactRaw[$i] -match '(React|@pweb/runtime)' -and
                $p2jRaw[$i] -notmatch '(Pas2JS|pweb\.native)') {
                Violation ("src/program.lpr line $($i + 1) drops the React " +
                    'name without naming Pas2JS')
            }
        }
    }
    if ($diffLines -ne 4) {
        Violation ("src/program.lpr differs on $diffLines line(s) between " +
            'the templates, expected exactly the 4 of the data-path comment')
    }
}
# no native source may name a frontend kind in CODE at all
foreach ($f in "$p2j/src/program.lpr", "$p2j/src/app.services.pas",
                "$react/src/program.lpr", "$react/src/app.services.pas") {
    foreach ($row in (Get-CodeLines $f)) {
        if ($row.Text -match '(?i)\b(react|pas2js|vite|tsx?)\b') {
            Violation ("$f names a frontend kind in CODE at line " +
                "$($row.Number): $($row.Text.Trim())")
        }
    }
}

# --- 3. the Pas2JS frontend IS the canonical one --------------------------
$appPas = [System.IO.File]::ReadAllText("$p2j/frontend/src/app.pas")
$entry = [System.IO.File]::ReadAllText("$p2j/frontend/src/program.lpr")
$canonical = [System.IO.File]::ReadAllText(
    'examples/05-pas2js/frontend/src/p2japp.pas')
# every SDK surface this template uses must be one the canonical CAP-5
# application uses too - which is what makes this a derivation of a proven
# frontend rather than an independent guess at the API
foreach ($api in 'pweb.native', 'PWebHandshake', 'PWebInvoke', 'EPWebError',
                 'TPWebRuntimeInfo', 'CalculatorService.Add') {
    if (-not $appPas.Contains($api)) {
        Violation ("the generated Pas2JS frontend does not use $api")
    }
    if (-not $canonical.Contains($api)) {
        Violation ("examples/05-pas2js no longer uses $api -- the template " +
            'is checked against it, so a canonical source that moved on ' +
            'silently is a template nobody is comparing any more')
    }
}
# the same logical call, argument names included: parameter names are public
# API, and a template that renamed one would be a different wire request
if ($appPas -notmatch "New\(\['a',\s*SUM_A,\s*'b',\s*SUM_B\]\)") {
    Violation ('the generated Pas2JS frontend does not send the ratified ' +
        "named arguments {a, b} to CalculatorService.Add")
}
foreach ($pair in @(@('SUM_A', '20'), @('SUM_B', '22'))) {
    if ($appPas -notmatch "$($pair[0])\s*=\s*$($pair[1])\s*;") {
        Violation ("the generated Pas2JS frontend does not define " +
            "$($pair[0]) = $($pair[1])")
    }
}
if (-not $canonical.Contains("New(['a', 20, 'b', 22])")) {
    Violation ('examples/05-pas2js no longer sends {a:20, b:22}')
}
# the typed refusal, with all three fields - `code` is the sole normative
# discriminator and the other two are asserted so a partial mapping cannot
# pass as a whole one
if ($appPas -notmatch "E\.Code\s*=\s*'forbidden'") {
    Violation 'the generated frontend does not check the forbidden code'
}
if ($appPas -notmatch 'E\.Status\s*=\s*403') {
    Violation 'the generated frontend does not check the 403 status'
}
if ($appPas -notmatch 'E\.Data\s*=\s*JS\.Null') {
    Violation 'the generated frontend does not check the null data'
}
# the entry point is a bootstrap and nothing else
if ((Get-CodeLines "$p2j/frontend/src/program.lpr").Count -gt 8) {
    Violation ('the generated Pas2JS entry point carries more than a ' +
        'bootstrap -- the application belongs in app.pas')
}
if ($entry -notmatch '(?m)^\s*RunApp;\s*$') {
    Violation 'the generated Pas2JS entry point does not call RunApp'
}

# --- 4. the generated application owns no raw binding ---------------------
$rawForms = @('__pweb_invoke', 'webkit.messageHandlers', 'chrome.webview')
$appRawHits = 0
foreach ($f in (Get-ChildItem $p2j -Recurse -File -Force)) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    foreach ($needle in $rawForms) {
        if ($text.Contains($needle)) {
            $appRawHits++
            Violation ("the pas2js template names the raw native binding " +
                "$needle in $($f.Name) -- the SDK owns that name")
        }
    }
}
# and the SDK is where it does live, spelled once, as a constant
$sdkText = [System.IO.File]::ReadAllText('sdk/pas2js/pweb.native.pas')
$sdkBindingDecls = @([regex]::Matches($sdkText,
    "PWEB_NATIVE_BINDING_NAME\s*=\s*'__pweb_invoke'")).Count
if ($sdkBindingDecls -ne 1) {
    Violation ("sdk/pas2js/pweb.native.pas declares the binding name " +
        "$sdkBindingDecls time(s), expected exactly 1")
}
if (@([regex]::Matches($sdkText, '__pweb_invoke')).Count -ne 1) {
    Violation ('sdk/pas2js/pweb.native.pas spells __pweb_invoke more than ' +
        'once -- one owner means one spelling')
}

# --- 5. a Pas2JS project needs no Node ------------------------------------
foreach ($banned in 'package.json', 'package-lock.json', 'node_modules',
                    'tsconfig.json', 'vite.config.ts', 'yarn.lock',
                    'pnpm-lock.yaml') {
    if (Test-Path (Join-Path $p2j $banned)) {
        Violation ("the pas2js template ships $banned -- a Pas2JS project " +
            'has no package manager, and nothing here exists to imitate the ' +
            'react template')
    }
}
foreach ($f in (Get-ChildItem $p2j -Recurse -File -Force)) {
    if ($f.Extension -in @('.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx')) {
        Violation ("the pas2js template ships JavaScript or TypeScript: " +
            "$($f.Name) -- the frontend is compiled FROM Pascal, and the " +
            'only handwritten JS in the application is the one-line ' +
            'rtl.run() bootstrap the BUILD emits')
    }
}
# the declared file set of the pas2js template, exactly
$p2jDeclared = @()
foreach ($m in [regex]::Matches($listText,
        '(?ms)^template = pas2js\s*$(.*?)(?=^template = |\z)')) {
    foreach ($fm in [regex]::Matches($m.Groups[1].Value,
            '(?m)^\s*file\s*=\s*(\S+)\s*$')) {
        $p2jDeclared += $fm.Groups[1].Value
    }
}
$p2jDeclared = @($p2jDeclared | Sort-Object -CaseSensitive)
$p2jExpected = @('README.md', 'frontend/app.css', 'frontend/index.html',
    'frontend/pas2js.cfg', 'frontend/src/app.pas',
    'frontend/src/program.lpr', 'gitattributes', 'gitignore',
    'src/app.services.pas', 'src/program.lpr') | Sort-Object -CaseSensitive
if (($p2jDeclared -join '|') -cne ($p2jExpected -join '|')) {
    Violation ("the pas2js template declares $($p2jDeclared -join ', '), " +
        "expected $($p2jExpected -join ', ')")
}

# --- 6. no platform conditional, no allow-all, no listener, no script -----
$platformRx = '\{\$\s*(?:ifdef|ifndef|elseif|if|else|endif)\b[^}]*\}'
$platformSym = '\b(WIN32|WIN64|WINDOWS|OSWINDOWS|MSWINDOWS|LINUX|DARWIN|UNIX|' +
    'POSIX|BSD|IOS|OSX|MACOS|ANDROID|CPUX86_64|CPUX64|CPUAARCH64|CPUARM64|' +
    'AARCH64|CPU32|CPU64)\b'
$generatedConditionals = 0
foreach ($f in "$p2j/src/program.lpr", "$p2j/src/app.services.pas",
                "$p2j/frontend/src/program.lpr", "$p2j/frontend/src/app.pas") {
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($f)) {
        $lineNo++
        foreach ($m in [regex]::Matches($line, $platformRx)) {
            if ($m.Value -match $platformSym) {
                # {$apptype console} needs OSWINDOWS and is the ONE allowed
                # conditional: it selects a SUBSYSTEM, not a behaviour
                if ($m.Value -notmatch 'OSWINDOWS') {
                    $generatedConditionals++
                    Violation ("the generated Pascal carries a platform " +
                        "conditional: ${f}:${lineNo}: $($m.Value)")
                }
            }
        }
    }
}
$generatedPascal = [System.IO.File]::ReadAllText("$p2j/src/app.services.pas") +
    "`n" + [System.IO.File]::ReadAllText("$p2j/src/program.lpr")
if ($generatedPascal -notmatch 'SetAppMaximum\(\[') {
    Violation ('the generated policy does not set an explicit AppMaximum -- ' +
        'no AppMaximum means no capabilities, and an implicit one would mean ' +
        'nobody stated the ceiling')
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
if ($generatedPascal -notmatch 'PWebHostRuntimeBridge') {
    Violation ('the generated application does not install the reusable ' +
        'runtime-command layer')
}
if ($generatedPascal -match 'external\.open') {
    Violation ('the generated policy grants external.open -- the sample ' +
        'application opens no link, so nothing should authorize it to')
}
# the frontend must reach the runtime through the SDK and through nothing
# else: no transport as DATA anywhere in the Pas2JS sources or the page.
#
# ONLY A STRING LITERAL COUNTS in the Pascal, which is the discipline the
# CAP-10B1 build proof already established: a comment that names a transport
# is how this repository EXPLAINS what it refuses - the generated app.pas
# opens by saying it uses no fetch, no WebSocket and no localhost - and a
# gate that could not tell a literal from its explanation would forbid the
# explanation. What must not exist is the transport as DATA.
$transportRx = 'localhost|127\.0\.0\.1|file://|http://|https://|ws://|wss://'
foreach ($f in "$p2j/frontend/src/app.pas", "$p2j/frontend/src/program.lpr",
                "$p2j/src/program.lpr", "$p2j/src/app.services.pas") {
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($f)) {
        $lineNo++
        foreach ($m in [regex]::Matches($line, "'((?:[^']|'')*)'")) {
            if ($m.Groups[1].Value -match $transportRx) {
                Violation ("${f}:${lineNo} names a transport as DATA: " +
                    $m.Groups[1].Value)
            }
        }
    }
}
# the page and its stylesheet carry no Pascal, so there is no comment form
# to distinguish and the whole text is the data
foreach ($f in "$p2j/frontend/index.html", "$p2j/frontend/app.css") {
    $text = [System.IO.File]::ReadAllText($f)
    if ($text -match $transportRx) {
        Violation "$f names a transport"
    }
}
# the compile options the project owns carry no path at all - a -Fu or an
# -o here would be an absolute host path in a portable tree
$cfg = [System.IO.File]::ReadAllText("$p2j/frontend/pas2js.cfg")
foreach ($line in ($cfg -split "`n")) {
    $t = $line.Trim()
    if (($t -eq '') -or $t.StartsWith('#')) { continue }
    if ($t -notmatch '^-(Tbrowser|Jc|Jirtl\.js|O1)$') {
        Violation ("frontend/pas2js.cfg carries an unratified option: $t")
    }
}

# --- 7. the documented surface is the compiled surface --------------------
$lock = [System.IO.File]::ReadAllText('pas2js.lock')
$lockVersion = ''
if ($lock -match '(?m)^version\s*=\s*(\S+)\s*$') { $lockVersion = $Matches[1] }
$toolchain = [System.IO.File]::ReadAllText('tools/pweb/pweb.cli.toolchain.pas')
$pinned = ''
if ($toolchain -match "PWEB_CLI_PAS2JS_VERSION:\s*RawUtf8\s*=\s*'([^']+)'") {
    $pinned = $Matches[1]
}
if ($lockVersion -eq '') {
    Violation 'pas2js.lock declares no version'
} elseif ($pinned -cne $lockVersion) {
    Violation ("PWEB_CLI_PAS2JS_VERSION is '$pinned' and pas2js.lock says " +
        "'$lockVersion' -- a pin that lives in two places is a pin that will " +
        'one day be two')
}
foreach ($doc in 'docs/cli-contract.md', 'docs/template-contract.md') {
    $text = [System.IO.File]::ReadAllText($doc)
    if (-not $text.Contains('--ui react|pas2js')) {
        Violation "$doc does not document the create grammar --ui react|pas2js"
    }
}
$cliDoc = [System.IO.File]::ReadAllText('docs/cli-contract.md')
foreach ($phrase in '| `frontend.pas2js` | required | `ui: pas2js` |',
                    '| Pas2JS | `== 3.0.1` exactly | `pas2js.lock` `version` |') {
    if (-not $cliDoc.Contains($phrase)) {
        Violation "docs/cli-contract.md does not record: $phrase"
    }
}
# and the doctor really is UI-aware, in the source rather than in prose
$doctorSource = [System.IO.File]::ReadAllText('tools/pweb/pweb.cli.doctor.pas')
foreach ($needed in "Project.Ui = puiPas2js", "'frontend.pas2js'",
                    "'ui_not_react'", "'ui_not_pas2js'") {
    if (-not $doctorSource.Contains($needed)) {
        Violation ("pweb.cli.doctor.pas does not carry the UI-aware rule " +
            "$needed")
    }
}

# --- the evidence this check produces -------------------------------------
New-Item -ItemType Directory -Force build/cap10b2 | Out-Null
$facts = [ordered]@{
    supported_uis              = $supportedUis
    public_template_ids        = ($publicIds -join ',')
    pas2js_template_files      = $p2jDeclared.Count
    shared_native_source_digest = $sharedNativeDigest
    shared_file_digests        = ($sharedDigests -join ';')
    native_comment_diff_lines  = $diffLines
    generated_conditionals     = $generatedConditionals
    app_raw_binding_hits       = $appRawHits
    sdk_binding_declarations   = $sdkBindingDecls
    pas2js_pin                 = $pinned
    violations                 = $violations.Count
}
[System.IO.File]::WriteAllText('build/cap10b2/contracts.json',
    (($facts | ConvertTo-Json -Depth 4) + "`n"),
    [System.Text.UTF8Encoding]::new($false))

if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Write-Host "CONTRACT VIOLATION: $v" }
    throw "CAP-10B2 contract cross-checks FAILED: $($violations.Count)"
}
Write-Host ("[CAP-10B2] contracts PASS - $supportedUis are the advertised " +
    "and the shipped UIs, the generated native application is one " +
    "application (code digest $($sharedNativeDigest.Substring(0, 12))..., " +
    "$diffLines comment lines apart), and no application source names the " +
    'raw native binding')
