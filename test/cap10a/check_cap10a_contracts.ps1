# CAP-10A contract cross-checks. Checkout-plus-build only: no toolchain, no
# network, no window - it runs in every platform job and on any dev host.
#
# FOUR THINGS ARE CHECKED, and each of them is a claim the CLI makes that
# would otherwise be a comment:
#
#   1. THE PINS ARE SINGLE-SOURCE. pweb.cli.toolchain carries the versions
#      `pweb doctor` compares against, because a generated project does not
#      carry this repository's lock files. Every one of those constants is
#      re-derived here from its lock (or from the workflow's own node pin) and
#      must match exactly. A constant nobody cross-checks is a number somebody
#      typed.
#
#   2. THERE IS NO SHELL. The CLI starts processes in exactly one unit, over
#      an argument array. This sweep refuses every spelling that would mean
#      otherwise - cmd.exe, /bin/sh, system(), popen, and mORMot's
#      RunRedirect/RunCommand, whose POSIX body IS popen.
#
#   3. THERE IS NO NETWORK AND NO CWD DEPENDENCE. The CLI's compiled unit set
#      (build/cap10b1/cli-units, which contains exactly what it links) may not
#      contain a networking unit, its sources may not name a transport, and
#      the working directory is read ONCE - the count is asserted, not hoped
#      for - and never changed.
#
#   4. THE COMMAND IS NOT DUPLICATED. pweb.openExternal is implemented in
#      src/rpc/pweb.rpc.command.pas and nowhere else. This is the gate that
#      keeps the CAP-8B staging copies from growing back.
#
# Usage: pwsh test/cap10a/check_cap10a_contracts.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
function Violation([string]$Text) { $violations.Add($Text) }

# Pascal CODE lines only. A comment may - and in this repository does - name
# the exact forms these sweeps refuse: every unit header explains which
# spellings are banned and why, and a gate that could not tell a ban from its
# own explanation would forbid the file from documenting itself.
#
# The tracker handles both Pascal block forms and the line form. It is
# deliberately simple: these are the repository's own sources, written in one
# house style, not arbitrary input.
function Get-CodeLines([string]$Path) {
    $lines = [System.IO.File]::ReadAllLines($Path)
    $inBrace = $false
    $inParen = $false
    $out = New-Object System.Collections.Generic.List[psobject]
    for ($i = 0; $i -lt $lines.Count; $i++) {
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
                    ($line[$j + 1] -eq ')')) { $inParen = $false; $j += 2 }
                else { $j++ }
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

function Read-LockKey([string]$File, [string]$Key) {
    if (-not (Test-Path -LiteralPath $File)) { throw "lock file missing: $File" }
    $hits = @(Select-String -Path $File -Pattern "^\s*$([regex]::Escape($Key))\s*=\s*(.+?)\s*$")
    if ($hits.Count -ne 1) {
        throw "expected exactly one '$Key' in ${File}, found $($hits.Count)"
    }
    return $hits[0].Matches[0].Groups[1].Value
}

function Read-PascalConst([string]$File, [string]$Name) {
    $hits = @(Select-String -Path $File -CaseSensitive `
        -Pattern "^\s*$([regex]::Escape($Name))\s*:?\s*[A-Za-z0-9]*\s*=\s*'([^']*)'\s*;")
    if ($hits.Count -ne 1) {
        throw "expected exactly one $Name in ${File}, found $($hits.Count)"
    }
    return $hits[0].Matches[0].Groups[1].Value
}

$toolchain = 'tools/pweb/pweb.cli.toolchain.pas'

# --- 1. the pins -----------------------------------------------------------
$fpcMin = Read-PascalConst $toolchain 'PWEB_CLI_FPC_MIN'
$fpcLock = Read-LockKey 'fpc.lock' 'version'
if ($fpcMin -cne $fpcLock) {
    Violation "PWEB_CLI_FPC_MIN=$fpcMin but fpc.lock version=$fpcLock"
}
$pas2js = Read-PascalConst $toolchain 'PWEB_CLI_PAS2JS_VERSION'
$pas2jsLock = Read-LockKey 'pas2js.lock' 'version'
if ($pas2js -cne $pas2jsLock) {
    Violation "PWEB_CLI_PAS2JS_VERSION=$pas2js but pas2js.lock version=$pas2jsLock"
}
$macosMin = Read-PascalConst $toolchain 'PWEB_CLI_MACOS_MIN'
$macosLock = Read-LockKey 'webview.lock' 'macos-deployment-target'
if ($macosMin -cne $macosLock) {
    Violation ("PWEB_CLI_MACOS_MIN=$macosMin but webview.lock " +
        "macos-deployment-target=$macosLock")
}
# Node has no lock file of its own: the pin lives in the workflow, and what
# must hold is that the version CI actually installs SATISFIES the floor the
# doctor requires. A floor above the pinned Node would fail every CI leg's
# own doctor run for a reason nobody could act on.
$nodeMin = Read-PascalConst $toolchain 'PWEB_CLI_NODE_MIN'
$nodePins = @(Select-String -Path '.github/workflows/ci.yml' `
    -Pattern '^\s*node-version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$')
if ($nodePins.Count -lt 1) {
    Violation 'no pinned node-version found in .github/workflows/ci.yml'
} else {
    foreach ($pin in $nodePins) {
        $pinned = [version]$pin.Matches[0].Groups[1].Value
        if ($pinned -lt [version]$nodeMin) {
            Violation ("the CI node pin $pinned is BELOW PWEB_CLI_NODE_MIN " +
                "$nodeMin -- doctor would fail on its own runner")
        }
    }
}
# the WebView2 minimum is NOT duplicated at all: the Windows engine row goes
# through the ratified CAP-6b0 detector, which owns PWEB_WV2_MIN_BUILD. This
# gate asserts the absence of a second copy rather than the agreement of two.
$wv2Copies = @(Select-String -Path 'tools/pweb/*.pas' -SimpleMatch -Pattern '1587')
if ($wv2Copies.Count -ne 0) {
    foreach ($h in $wv2Copies) {
        Violation ("the WebView2 minimum build is re-spelled in " +
            "$($h.Path):$($h.LineNumber) -- it belongs to the CAP-6b0 detector")
    }
}

# --- 2. no shell -----------------------------------------------------------
# (patterns are concatenated so this file cannot match its own source)
$shellPatterns = @(
    ('cm' + 'd.exe'), ('/bin/' + 'sh'), ('/bin/' + 'bash'),
    ('sys' + 'tem('), ('po' + 'pen'), ('Run' + 'Redirect'),
    ('Run' + 'Command'), ('Execute' + 'Process'), ('Shell' + 'Execute'),
    ('Comm' + 'andLine :='), ('po' + 'RunSuspended')
)
# the UNITS, without the program: the program is allowed to do exactly one
# thing the units are not, and the working-directory rule below depends on
# telling the two apart.
#
# pwebtemplates.pas is excluded for the same reason pweb.pas is, and the
# distinction is worth stating rather than assuming. It is a BUILD TOOL, not
# part of the CLI: it is never linked into `pweb`, it is not installed, and
# CAP-10B0's own contract check MEASURES both of those against the CLI's
# compiled unit set. The working-directory rule exists because a shipped
# command must not resolve anything from where it happened to be invoked; a
# build tool that takes an explicit --source argument and makes it absolute
# is doing the opposite of that, and forbidding it would forbid the argument.
# the CLI's UNIT set: every .pas under tools/pweb except the PROGRAMS. There
# are three programs, each a separate main whose absence from the shipped
# executable its own shard measures - `pweb.pas` (the CLI itself),
# `pwebtemplates.pas` (the CAP-10B0 pack builder) and, since CAP-10D2,
# `pwebsdk.pas` (the SDK packager). A program legitimately resolves its own
# working directory and writes its own summary; a UNIT may do neither.
# CAP-10D2 SUPERSESSION: the excluded set moves from two programs to three.
$cliSources = @(Get-ChildItem tools/pweb -File -Filter '*.pas' |
    Where-Object { ($_.Name -cne 'pweb.pas') -and
                   ($_.Name -cne 'pwebtemplates.pas') -and
                   ($_.Name -cne 'pwebsdk.pas') })
if ($cliSources.Count -lt 8) {
    Violation "expected the CLI unit set under tools/pweb, found $($cliSources.Count)"
}
foreach ($src in $cliSources) {
    foreach ($row in (Get-CodeLines $src.FullName)) {
        foreach ($pat in $shellPatterns) {
            if ($row.Text.Contains($pat)) {
                Violation ("SHELL CONSTRUCTION: $($src.Name):$($row.Number): " +
                    $row.Text.Trim())
            }
        }
    }
}

# --- 3. no network, no CWD dependence --------------------------------------
$netPatterns = 'mormot\.net\.|TRestHttpServer|THttpServer|localhost|' +
    '127\.0\.0\.1|https?://|wss?://|\bsocket\b|WinSock|WSAStartup'
foreach ($src in @($cliSources) + @(Get-Item 'tools/pweb/pweb.pas')) {
    foreach ($row in (Get-CodeLines $src.FullName)) {
        if ($row.Text -match $netPatterns) {
            Violation ("NETWORK REFERENCE: $($src.Name):$($row.Number): " +
                $row.Text.Trim())
        }
    }
}
# the compiled unit set is the load-bearing half of the same claim
if (Test-Path 'build/cap10b1/cli-units') {
    $linked = @(Get-ChildItem 'build/cap10b1/cli-units' -File -Filter '*.ppu')
    if ($linked.Count -lt 5) {
        Violation ('build/cap10b1/cli-units holds no compiled unit set -- ' +
            'run test/cap10b1/build_cap10b1.ps1 before this gate')
    }
    foreach ($u in $linked) {
        if ($u.Name -match '^mormot\.net\.' -or $u.Name -match '^(sockets|ssockets)\.') {
            Violation "the CLI LINKS a networking unit: $($u.Name)"
        }
    }
} else {
    Violation 'build/cap10b1/cli-units is missing -- run test/cap10b1/build_cap10b1.ps1 first'
}
# THE WORKING DIRECTORY IS READ EXACTLY ONCE, at startup, and that is a
# property of the CALL GRAPH rather than of a grep: the platform seam owns the
# only OS-level read (in two forms, because the Windows API is a two-call
# idiom), and the whole rest of the CLI reaches it through PWebCliCwd - which
# the program must call exactly once and no other unit may call at all.
foreach ($src in $cliSources) {
    if ($src.Name -ceq 'pweb.cli.platform.pas') { continue }
    foreach ($row in (Get-CodeLines $src.FullName)) {
        if ($row.Text -match 'GetCurrentDir|GetCurrentDirectory') {
            Violation ("the working directory is read outside the platform " +
                "seam: $($src.Name):$($row.Number)")
        }
        if ($row.Text -match 'PWebCliCwd') {
            Violation ("only the program may resolve the working directory: " +
                "$($src.Name):$($row.Number)")
        }
    }
}
$programCwd = @(Get-CodeLines 'tools/pweb/pweb.pas' |
    Where-Object { $_.Text -match 'PWebCliCwd' })
if ($programCwd.Count -ne 1) {
    Violation ("the program must resolve the working directory EXACTLY once, " +
        "found $($programCwd.Count)")
}
# and nothing in the CLI may CHANGE it
foreach ($src in @($cliSources) + @(Get-Item 'tools/pweb/pweb.pas')) {
    foreach ($row in (Get-CodeLines $src.FullName)) {
        if ($row.Text -match 'SetCurrentDir|SetCurrentDirectory|\bChDir\b') {
            Violation ("the CLI CHANGES the working directory: " +
                "$($src.Name):$($row.Number)")
        }
    }
}

# --- 4. the external-open command exists exactly once ----------------------
#
# TWO different rules, because a wire name and an implementation are two
# different things. Both sides of a wire necessarily spell the method: the
# Pas2JS frontend, the TypeScript SDK and the QuickJS harnesses all name it
# because they CALL it, and forbidding that would forbid having a wire.
#
#   Rule A - on the PRODUCTION Pascal surface (src, examples, tools), the
#   literal may be declared in pweb.rpc.command and nowhere else. That is the
#   rule that stops the CAP-8B staging copies growing back into every host
#   CAP-10B is about to generate.
#
#   Rule B - TREE-WIDE, no file but pweb.rpc.command may contain the command's
#   SHAPE: the shared validator followed by the invalid_request envelope. That
#   is a structural test for a second implementation, and it is what the four
#   copies this shard deleted would have failed.
$literal = 'pweb.' + 'openExternal'
$owner = 'src/rpc/pweb.rpc.command.pas'
# examples/**/frontend/** is deliberately outside Rule A: those are FRONTEND
# sources compiled to JavaScript by Pas2JS. They cannot use a native unit, so
# they must spell the wire name they call, exactly as the TypeScript SDK does.
$productionPascal = @(
    (Get-ChildItem src -Recurse -File -Include '*.pas', '*.inc'),
    (Get-ChildItem examples -Recurse -File -Include '*.pas' |
        Where-Object { $_.FullName -notmatch '[\\/]frontend[\\/]' }),
    (Get-ChildItem tools -Recurse -File -Include '*.pas')
) | ForEach-Object { $_ }
foreach ($src in $productionPascal) {
    $rel = ($src.FullName.Substring($repoRoot.Length).TrimStart('\', '/')) `
        -replace '\\', '/'
    foreach ($row in (Get-CodeLines $src.FullName)) {
        if (($row.Text -match "=\s*'$([regex]::Escape($literal))'") -and
            ($rel -cne $owner)) {
            Violation ("Rule A: the external-open method literal is " +
                "re-declared in ${rel}:$($row.Number)")
        }
    }
}
$allPascal = @(
    (Get-ChildItem src, examples, tools, test -Recurse -File `
        -Include '*.pas', '*.inc' -ErrorAction SilentlyContinue)
)
foreach ($src in $allPascal) {
    $rel = ($src.FullName.Substring($repoRoot.Length).TrimStart('\', '/')) `
        -replace '\\', '/'
    if ($rel -ceq $owner) { continue }
    $code = (Get-CodeLines $src.FullName | ForEach-Object { $_.Text }) -join "`n"
    # the shape is CONSTRUCTING the refusal, not merely naming the code: a
    # suite that ASSERTS `r.Error.Code = pecInvalidRequest` is testing the
    # owner, and a gate that could not tell those apart would forbid the
    # owner from having a test
    if (($code -match 'PWebValidExternalUri') -and
        ($code -match 'PWebDefaultErrorResult\(\s*pecInvalidRequest\s*\)')) {
        Violation ("Rule B: ${rel} carries the SHAPE of a second " +
            'external-open implementation (the shared validator plus a ' +
            'constructed invalid_request envelope)')
    }
}

# --- verdict ---------------------------------------------------------------
if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Write-Host "VIOLATION: $v" }
    throw "CAP-10A contract cross-checks FAILED: $($violations.Count) violation(s)"
}
Write-Host ('[CAP-10A] contracts PASS - pins single-source, no shell, ' +
    'no network, one CWD read, one external-open implementation')
