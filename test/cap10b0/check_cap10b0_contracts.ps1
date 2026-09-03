# CAP-10B0 contract cross-checks. Checkout-plus-build only: no toolchain, no
# network, no window - it runs in every platform job and on any dev host.
#
# SIX THINGS ARE CHECKED, and each of them is a claim CAP-10B0 makes that
# would otherwise be a comment:
#
#   1. `pweb create` IS PRESENT BY LINKAGE, not merely by dispatch - the
#      CAP-10B0 rule, INVERTED by CAP-10B1 rather than deleted. The CLI's
#      compiled unit set - build/cap10b1/cli-units, which contains exactly
#      what pweb links - must now contain every scaffold-engine unit, and
#      tools/pweb/pweb.pas must name them in its uses clause. `dev`, `run`
#      and `build` are still absent from the parser. A rule that is removed
#      the moment it stops holding was never load-bearing; the same
#      measurement simply has to come out the other way.
#
#   2. THE ENGINE IS OFFLINE AND STARTS NOTHING. Its sources may not name a
#      transport, a process API, a shell, a package manager or a compiler,
#      and the builder's compiled unit set may not contain a networking
#      unit. `pweb create` writes files; it does not fetch, install or
#      build, and there is no code path through which it could.
#
#   3. THE SDK ROOT HAS NO ENVIRONMENT BACK DOOR. No engine source reads an
#      environment variable at all. A developer tool that can be pointed at
#      a different SDK by exporting a variable is a tool whose trusted input
#      is whatever the last shell profile said it was.
#
#   4. THE TRUSTED SOURCE IS FULLY TRACKED. Every file under
#      tools/templates/ is known to git, in both directions. A template
#      corpus with an untracked file in it is a corpus whose review does not
#      cover what the builder packs - and a `.gitignore` in a template tree
#      is exactly how that happens by accident.
#
#   5. THE TRUSTED SOURCE IS LF AND CARRIES NO SECRET. The builder refuses
#      both, but this runs on a bare checkout, before anything is compiled,
#      so a CRLF checkout is diagnosed as a CHECKOUT problem rather than as
#      a mysterious Windows-only build failure.
#
#   6. THE DOCUMENTED LIMITS ARE THE COMPILED LIMITS. Every bound in
#      docs/template-contract.md is re-derived from its Pascal constant. A
#      number in a contract that nobody cross-checks is a number somebody
#      typed.
#
# It writes build/cap10b0/contracts.json, which run_cap10b0_gates.ps1 folds
# into this target's evidence - so the offline claim in the corpus is backed
# by these measurements rather than asserted beside them.
#
# Usage: pwsh test/cap10b0/check_cap10b0_contracts.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
function Violation([string]$Text) { $violations.Add($Text) }

# Pascal CODE lines only. A comment may - and in this repository does - name
# the exact forms these sweeps refuse: every unit header explains which
# spellings are banned and why, and a gate that could not tell a ban from
# its own explanation would forbid the file from documenting itself.
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

$engineSources = @(
    'tools/pweb/pweb.cli.sdk.pas',
    'tools/pweb/pweb.cli.template.pas',
    'tools/pweb/pweb.cli.scaffold.pas',
    'tools/pweb/pweb.cli.write.pas',
    'tools/pweb/pwebtemplates.pas'
)
foreach ($src in $engineSources) {
    if (-not (Test-Path $src)) { throw "missing engine source: $src" }
}

# --- 1. `pweb create` is present by LINKAGE -------------------------------
#
# INVERTED BY CAP-10B1, deliberately rather than deleted. CAP-10B0's claim
# was that the scaffold engine was not linked into the public CLI at all,
# and it was measured against the CLI's own compiled unit set. CAP-10B1
# exposes the command, so the SAME measurement now has to come out the other
# way - because a rule that is removed when it stops holding is a rule that
# was never load-bearing. What is checked is unchanged: what the binary
# actually links, not what the help text says.
#
# The unit set moved with the executable. CAP-10B1 builds the one `pweb`,
# because the CLI compiles a generated template registry in with -Fi and
# cannot exist before the pack that registry describes.
$cliUnits = 'build/cap10b1/cli-units'
$engineUnits = @('pweb.cli.template', 'pweb.cli.scaffold', 'pweb.cli.write',
    'pweb.cli.sdk')
$createLinked = 'unmeasured'
if (Test-Path $cliUnits) {
    $createLinked = 'linked'
    foreach ($u in $engineUnits) {
        $hit = @(Get-ChildItem $cliUnits -File |
            Where-Object { $_.BaseName -ieq $u })
        if ($hit.Count -eq 0) {
            $createLinked = 'ABSENT'
            Violation ("the scaffold engine unit $u is NOT in $cliUnits -- " +
                'CAP-10B1 exposes `pweb create`, so the engine has to be in ' +
                'the executable that offers it')
        }
    }
} else {
    Violation ("$cliUnits is absent -- run test/cap10b1/build_cap10b1.ps1 " +
        'first; the linkage claim is a MEASUREMENT over the CLI unit set ' +
        'and cannot be made without it')
}

# the program's own uses clause, independently of what got compiled
$programUses = (Get-CodeLines 'tools/pweb/pweb.pas' |
    ForEach-Object { $_.Text }) -join ' '
foreach ($u in $engineUnits) {
    if ($programUses -notmatch [regex]::Escape($u)) {
        Violation "tools/pweb/pweb.pas does not name the scaffold unit $u"
    }
}
# create exists; dev, run and build still do not, and they are still absent
# from the parser rather than present and refusing
$argsSource = [System.IO.File]::ReadAllText('tools/pweb/pweb.cli.args.pas')
if ($argsSource -notmatch 'pccCreate\b') {
    Violation "tools/pweb/pweb.cli.args.pas defines no 'create' command"
}
# CAP-10C0 moved `run` out of this list and CAP-10C2 moved `dev`: each is a
# command that does the whole of what its name says now, and its own shard's
# gates measure it. `build` stays unknown until the shard that makes it true.
foreach ($cmd in 'build') {
    if ($argsSource -match "pccC?$cmd\b") {
        Violation "tools/pweb/pweb.cli.args.pas defines a '$cmd' command"
    }
}

# --- 2. the engine is offline and starts nothing --------------------------
# Each pattern is a SPELLING of a capability CAP-10B0 refuses to have.
#
# WHAT IS DELIBERATELY NOT HERE: the words `fpc` and `pas2js`. They are
# schema-1 DESCRIPTOR VOCABULARY - `ui` is exactly `react` or `pas2js`, and
# the engine has to be able to say so - and banning a word the contract
# requires would make this sweep an argument against the contract. What
# actually prevents a compiler from running is the process-API ban below:
# with no exec, no fork, no CreateProcess and no shell anywhere in these
# units, there is no mechanism for a tool name to become an invocation, and
# a ban on the mechanism beats a ban on the noun.
$bannedApis = @{
    'mormot\.net'          = 'a networking unit'
    '\bTProcess\b'         = 'a process launcher'
    '\bRunCommand\b'       = 'mORMot RunCommand'
    '\bRunRedirect\b'      = 'mORMot RunRedirect (its POSIX body is popen)'
    '\bCreateProcess\w*\b' = 'the Win32 process API'
    '\bShellExecute\w*\b'  = 'the Win32 shell API'
    '\bWinExec\b'          = 'the Win32 legacy exec API'
    '\bfpExecv\w*\b'       = 'the POSIX exec family'
    '\bfpFork\b'           = 'fork(2)'
    '\bpopen\b'            = 'popen(3)'
    'cmd\.exe'             = 'the Windows shell'
    '/bin/sh'              = 'the POSIX shell'
    '\bnpm\b'              = 'a package manager'
    '\bpnpm\b'             = 'a package manager'
    '\byarn\b'             = 'a package manager'
    '\bWinHttp\w*\b'       = 'an HTTP client'
    '\bTHttpClient\w*\b'   = 'an HTTP client'
    '\bTNetSocket\b'       = 'a socket'
}
# The environment patterns match the API that READS one, plus the three
# variable names quoted as STRING LITERALS - which is how a name would have
# to appear to be looked up. The unquoted forms are ordinary Pascal
# identifiers (PWEB_SDK_BIN, PWEB_SDK_SHARE) and naming a constant after
# the layout it describes is not a back door.
$envApis = @{
    '\bGetEnvironmentVariable\b' = 'an environment read'
    '\bGetEnvironmentStrings\b'  = 'an environment read'
    '\bfpGetEnv\b'               = 'an environment read'
    '\bgetenv\b'                 = 'an environment read'
    "'PWEB_HOME'"                = 'an SDK environment override'
    "'PWEB_SDK'"                 = 'an SDK environment override'
    "'PWEB_TEMPLATES'"           = 'an SDK environment override'
}
$processApis = 0
$environmentReads = 0
foreach ($src in $engineSources) {
    foreach ($line in (Get-CodeLines $src)) {
        foreach ($rx in $bannedApis.Keys) {
            if ($line.Text -match $rx) {
                $processApis++
                Violation ("$src`:$($line.Number): the scaffold engine " +
                    "names $($bannedApis[$rx]): $($line.Text.Trim())")
            }
        }
        foreach ($rx in $envApis.Keys) {
            if ($line.Text -match $rx) {
                $environmentReads++
                Violation ("$src`:$($line.Number): the scaffold engine " +
                    "performs $($envApis[$rx]): $($line.Text.Trim())")
            }
        }
    }
}

# the builder's compiled unit set: what it LINKS, not what it mentions
$toolUnits = 'build/cap10b0/tool-units'
$networkUnits = 'unmeasured'
if (Test-Path $toolUnits) {
    $net = @(Get-ChildItem $toolUnits -File -Filter '*.ppu' |
        Where-Object { $_.BaseName -like 'mormot.net*' })
    $networkUnits = $net.Count
    foreach ($n in $net) {
        Violation ("the template builder LINKS a networking unit: " +
            "$($n.Name) in $toolUnits")
    }
} else {
    Violation ("$toolUnits is absent -- run test/cap10b0/build_cap10b0.ps1 " +
        'first; the offline claim is a measurement over the linked unit ' +
        'set and cannot be made without it')
}

# --- 4. the trusted source is fully tracked, both directions --------------
$declared = @(& git ls-files 'tools/templates' 2>$null)
if ($LASTEXITCODE -ne 0) {
    Violation 'git ls-files failed -- the tracked-source check cannot run'
    $declared = @()
}
$onDisk = @(Get-ChildItem 'tools/templates' -Recurse -File |
    ForEach-Object {
        $_.FullName.Substring($repoRoot.Length + 1) -replace '\\', '/'
    })
foreach ($f in $onDisk) {
    if ($declared -notcontains $f) {
        Violation ("untracked file in the trusted template source: $f -- a " +
            'template corpus git does not track is a corpus nobody reviewed')
    }
}
foreach ($f in $declared) {
    if ($onDisk -notcontains $f) {
        Violation "tracked but missing from the template source: $f"
    }
}

# --- 5. the trusted source is LF and carries no secret --------------------
# .cfg joined in CAP-10B2: the Pas2JS template ships frontend/pas2js.cfg,
# which is text the pack builder refuses a CR in - so the checkout sweep has
# to be able to see it, or a CRLF checkout would be diagnosed as a build
# failure rather than as a checkout problem.
$textExt = @('.md', '.txt', '.json', '.js', '.mjs', '.css', '.html', '.svg',
    '.lpr', '.lpi', '.pas', '.inc', '.cfg', '.sh', '.list')
$crFiles = 0
foreach ($f in (Get-ChildItem 'tools/templates' -Recurse -File)) {
    $rel = $f.FullName.Substring($repoRoot.Length + 1) -replace '\\', '/'
    $isText = ($textExt -contains $f.Extension.ToLowerInvariant()) -or
        ($f.Name -in @('gitignore', 'gitattributes', 'templates.list'))
    if (-not $isText) { continue }
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if ($bytes -contains 13) {
        $crFiles++
        Violation ("CR byte in a text template source: $rel -- the pack " +
            'builder refuses this outright, so a CRLF CHECKOUT would fail ' +
            'the build on Windows and pass everywhere else. Check ' +
            '.gitattributes covers tools/templates/**')
    }
    if (($bytes.Length -gt 0) -and ($bytes[$bytes.Length - 1] -ne 10)) {
        Violation "no final newline in a text template source: $rel"
    }
}
# and the .gitattributes block that keeps it that way
$attrs = [System.IO.File]::ReadAllText('.gitattributes')
foreach ($needed in 'tools/templates/** -text',
                    'tools/templates/templates.list text eol=lf') {
    if (-not $attrs.Contains($needed)) {
        Violation ".gitattributes is missing the pin: $needed"
    }
}

# --- 6. the documented limits ARE the compiled limits ---------------------
$tplSource = [System.IO.File]::ReadAllText('tools/pweb/pweb.cli.template.pas')
$scaffoldSource =
    [System.IO.File]::ReadAllText('tools/pweb/pweb.cli.scaffold.pas')
$doc = 'docs/template-contract.md'
if (-not (Test-Path $doc)) {
    Violation "missing $doc"
} else {
    $docText = [System.IO.File]::ReadAllText($doc)
    # name -> the exact literal the Pascal constant must carry, and the
    # exact string the document must print for it
    $limits = @(
        @{ Name = 'PWEB_TPL_PACK_MAX_BYTES';    Pascal = 'Int64(8) shl 20';  Doc = '8 MiB' }
        @{ Name = 'PWEB_TPL_FILE_MAX_BYTES';    Pascal = 'Int64(1) shl 20';  Doc = '1 MiB' }
        @{ Name = 'PWEB_TPL_TOTAL_MAX_BYTES';   Pascal = 'Int64(16) shl 20'; Doc = '16 MiB' }
        @{ Name = 'PWEB_TPL_MAX_ENTRIES';       Pascal = '512';              Doc = '512' }
        @{ Name = 'PWEB_TPL_MAX_TEMPLATES';     Pascal = '8';                Doc = '8' }
        @{ Name = 'PWEB_TPL_MAX_OUTPUT_FILES';  Pascal = '256';              Doc = '256' }
        @{ Name = 'PWEB_TPL_PATH_MAX_BYTES';    Pascal = '240';              Doc = '240' }
        @{ Name = 'PWEB_TPL_SEGMENT_MAX_BYTES'; Pascal = '128';              Doc = '128' }
        @{ Name = 'PWEB_TPL_TOKEN_MAX_BYTES';   Pascal = '128';              Doc = '128' }
        @{ Name = 'PWEB_TPL_LIST_MAX_BYTES';    Pascal = '64 shl 10';        Doc = '64 KiB' }
        @{ Name = 'PWEB_TPL_ID_MAX_BYTES';      Pascal = '32';               Doc = '32' }
    )
    foreach ($l in $limits) {
        $rx = [regex]::Escape($l.Name) + '\s*=\s*' +
            [regex]::Escape($l.Pascal) + '\s*;'
        if ($tplSource -notmatch $rx) {
            Violation ("$($l.Name) is not `"$($l.Pascal)`" in " +
                'pweb.cli.template.pas')
        }
        if ($docText -notmatch ([regex]::Escape($l.Name) + '[^\r\n]*' +
                [regex]::Escape($l.Doc))) {
            Violation ("$doc does not document $($l.Name) as " +
                "$($l.Doc)")
        }
    }
    # the two scaffold constants the document also prints
    if ($scaffoldSource -notmatch
        "PWEB_SCAFFOLD_INITIAL_VERSION\s*=\s*'0\.1\.0'") {
        Violation 'PWEB_SCAFFOLD_INITIAL_VERSION is not 0.1.0'
    }
    if ($scaffoldSource -notmatch 'PWEB_SCAFFOLD_NAME_MAX_BYTES\s*=\s*64\s*;') {
        Violation 'PWEB_SCAFFOLD_NAME_MAX_BYTES is not 64'
    }
    # the six tokens, in one place in the code and one place in the document
    foreach ($tok in 'PROJECT_NAME', 'PASCAL_PROGRAM', 'EXECUTABLE_NAME',
                     'BUNDLE_ID', 'PROJECT_VERSION', 'UI_KIND') {
        if ($scaffoldSource -notmatch "'$tok'") {
            Violation "the token $tok is not in the scaffold allowlist"
        }
        if (-not $docText.Contains($tok)) {
            Violation "$doc does not document the token $tok"
        }
    }
}

# --- the evidence this check produces -------------------------------------
New-Item -ItemType Directory -Force build/cap10b0 | Out-Null
$contracts = [ordered]@{
    create_linked     = $createLinked
    network_units     = $networkUnits
    process_apis      = $processApis
    environment_reads = $environmentReads
    template_sources  = $onDisk.Count
    cr_files          = $crFiles
    violations        = $violations.Count
}
[System.IO.File]::WriteAllText('build/cap10b0/contracts.json',
    (($contracts | ConvertTo-Json -Depth 4) + "`n"),
    [System.Text.UTF8Encoding]::new($false))

if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Write-Host "CONTRACT VIOLATION: $v" }
    throw "CAP-10B0 contract cross-checks FAILED: $($violations.Count)"
}
Write-Host ('[CAP-10B0] contracts PASS - create ' + $createLinked +
    " from the CLI unit set, $($onDisk.Count) tracked template sources, " +
    '0 process/network/environment APIs in the engine')
