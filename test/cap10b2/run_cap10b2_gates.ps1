# CAP-10B2: run the Pas2JS create gates against the REAL compiled CLI and
# emit this target's evidence.
#
# ONE script for all four targets. Everything here is headless: no window, no
# display, no network and no package manager. The Pas2JS build proof and the
# real GUI run live in prove_cap10b2.ps1/.sh, because those genuinely need a
# compiler and a desktop session and these gates must not.
#
# WHAT IT PROVES, and why each leg is a leg:
#
#   - THE SECOND FRONTEND IS REAL. `pweb create demo --ui pas2js` succeeds
#     against the shipped CLI and produces the exact eleven-file project this
#     shard ratified - asserted as a SET, in both directions, because a
#     project that grew a file and one that lost a file are both failures and
#     neither shows up in a count;
#
#   - THE REFUSALS ARE REAL, CATEGORISED, AND INCLUDE THE ONE THAT MOVED.
#     Nine bad command lines, three broken installations and one occupied
#     destination are executed, each required to produce its own
#     machine-stable cause AND its exit category. Two of them are new
#     ground: the refusal CAP-10B2 re-categorised - a CLI whose registry
#     does not describe the pas2js template answers 4 with
#     `template_unknown`, proven with a SECOND EXECUTABLE compiled against a
#     react-only pack because that branch is unreachable from the shipped
#     one - and the exit-3 destination arm, which CAP-10B0 proved in-process
#     against a synthetic plan and which no gate had ever watched become a
#     process exit code;
#
#   - THE OUTPUT IS A FUNCTION OF THE INPUTS. The same project is created
#     from three different working directories - one ordinary, one whose path
#     contains a space, one whose path contains non-ASCII characters - and
#     all three trees must be byte-identical;
#
#   - THERE IS ONE GENERATED NATIVE APPLICATION. For the same NAME and
#     bundle identifier the two projects are compared file by file: the
#     service unit and `.gitattributes` byte-identical, the entry point
#     identical once comments are removed, `pweb.json` different in `ui` and
#     in nothing else;
#
#   - REACT DID NOT DRIFT. The React project is created here too and its
#     inventory digest is compared to the CAP-10B1 CLOSURE value - an
#     absolute pin, not an agreement, because four targets can agree and
#     still be wrong together;
#
#   - BOTH PROJECTS ARE PROJECTS. The real `pweb doctor` is run against each
#     and its UI-awareness is asserted from the report rather than from the
#     source.
#
# Emits build/cap10b2/cli-<target>.json and leaves the reference Pas2JS
# project at build/cap10b2/project/demo for prove_cap10b2 to relocate and
# build.
#
# Usage: pwsh test/cap10b2/run_cap10b2_gates.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

# CAP-10D0: the ONE pwsh argument-quoting helper, dot-sourced rather than
# reimplemented. `Start-Process -ArgumentList <array>` joins the array with
# single spaces and quotes nothing, so a path carrying a space splits into
# two arguments and `--project` takes half of it. Start-PWebProcess quotes
# by the C runtime's rules - the same ones PWebCliWindowsCommandLine
# implements and the CAP-10C0 golden table proves on four targets.
. (Join-Path $repoRoot 'test/cap10d0/psargs.ps1')

# THE CAP-10B1 CLOSURE VALUE, pinned here on purpose.
#
# It is the SHA-256 of the generated React project's inventory projection,
# recorded by run 33127976094 and re-ratified by 33129150289 (15 files,
# 65765 bytes). CAP-10B2 adds a template beside the react one, which changes
# the pack, the registry and the CLI - so "React still produces the same
# bytes" is precisely the thing that could break silently while every new
# Pas2JS gate stayed green.
#
# If a future shard changes the React template deliberately, this constant
# moves in the same commit, with the reason recorded in that shard's
# artifact. It is not maintenance noise; it is the closure.
#
# SUPERSEDED BY CAP-10C1, which was that shard. It added `Flush(Output)`
# after the starter's ready report in src/app.services.pas and after the
# banner in src/program.lpr, in BOTH public templates: FPC's text layer
# flushes a pipe per line on Windows and BLOCK-BUFFERS it on Linux and macOS,
# so a supervisor read a generated host's lines only when the host exited.
# The file count was unchanged at 15; the projection moved from
# 1ca77cbb8dc0fed5844fa6aa958ca2727ea560f5bda0b50b23e1bd9b360f3230 and the
# total from 65765 bytes, and hosted run 33665009021 measured the new pair
# IDENTICALLY on all four targets - which is what makes it a template change
# rather than a host difference.
#
# SUPERSEDED AGAIN BY CAP-10C2, which is the shard that adds `pweb dev`. It
# moves the React template in three ways, and the FILE COUNT moves with it -
# 15 -> 16:
#
#   frontend/vite.config.ts   gains the `pweb-dev-sentinel` writeBundle
#                             plugin, which writes
#                             <frontend>/.pweb/dev/build-id on every
#                             completed build. That file is the dev loop's
#                             completion signal, it is written OUTSIDE dist/
#                             so no app.pwb digest moves, and .pweb/ is
#                             already inside the ratified mutation set;
#   frontend/pweb-build.d.ts  NEW: ambient declarations for the four Node
#                             built-ins that config now imports, so the
#                             typecheck stays strict without @types/node
#                             entering a lockfile shared with src/;
#   frontend/tsconfig.json    includes it;
#   src/program.lpr           selects pweb.webview.devhost under
#                             {$ifdef PWEB_DEV} - the ONE place the build
#                             mode is chosen, and it is native-controlled.
#
# The Pas2JS template is UNTOUCHED by this shard, which is why only the
# React trio moves here.
#
# 16 -> 16, and 71416 -> 72784 bytes. THE VALUE IS FOR A PROJECT NAMED
# `demo`, which is what this gate and test/cap10b1 both scaffold: the
# project name is substituted into the generated files, so the same template
# measured through a project named `demoreact` reads 100 bytes larger. A pin
# taken from the wrong project name is a pin that goes red on a runner for a
# reason that has nothing to do with the template - measured, once.
#
# CAP-10D0 SUPERSEDES README.md IN BOTH TEMPLATES. The B1/B2 READMEs
# described creation's next steps without naming a command, because until
# CAP-10D0 the command that takes them did not exist - `pweb build` was an
# unknown command and the README could not honestly name it. It exists now,
# so both READMEs document the five commands - create, doctor, build, dev,
# run - and the React one stops implying that some unnamed future build will
# materialise `.pweb/sdk/typescript`: `pweb build` and `pweb dev` do, and it
# says so.
#
# NO FILE WAS ADDED OR REMOVED, which is why the count does not move; only
# README.md's bytes did. Nothing in dist/ changed either, so no `app.pwb`
# digest moves - CAP-10D0 re-measures every c1_app_pwb_* and records them
# unchanged rather than claiming they are.
$CAP10B1_REACT_INVENTORY_DIGEST =
    '578a30933f3a37d66fac5f9ac554e5fb92227ca5ba839e4e57647301eaa145f0'
$CAP10B1_REACT_FILE_COUNT = 16
$CAP10B1_REACT_TOTAL_BYTES = 72784

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$work = Join-Path $repoRoot 'build/cap10b2'
$pweb = Join-Path $repoRoot "build/cap10b1/sdk/bin/pweb$exeSuffix"
$pack = Join-Path $repoRoot 'build/cap10b1/sdk/share/pweb/pweb-templates.zip'
$reactOnly = Join-Path $work "react-only/sdk/bin/pweb$exeSuffix"
foreach ($pre in $pweb, $pack, $reactOnly) {
    if (-not (Test-Path -LiteralPath $pre)) {
        throw ("missing precondition: $pre -- run test/cap10b1/build_cap10b1 " +
            'and test/cap10b2/build_cap10b2 first')
    }
}

if ($IsWindows) { $target = 'windows-x86_64' }
elseif ($IsLinux) { $target = 'linux-x86_64' }
elseif ($IsMacOS) {
    $target = if ((uname -m).Trim() -eq 'arm64') { 'macos-arm64' }
              else { 'macos-x86_64' }
} else { throw 'unsupported host' }
Write-Host "[CAP-10B2] target: $target"

# THE PINNED COMPILER IS PUT ON PATH BY THIS GATE, deliberately and visibly.
#
# `pweb doctor` resolves tools on PATH by ratified design (CAP-10A §"Executable
# resolution"), and every CI job fetches the pinned Pas2JS into deps/ without
# putting it there. So the gate arranges the one condition its own question
# needs - "is the pinned compiler findable?" - instead of recording an absence
# that says more about the runner's profile than about the project.
#
# It PREPENDS rather than replaces: whatever else a host carries stays
# visible, which is why `tool_duplicated` is a recorded observation below
# rather than a failure. What is ASSERTED is the version the doctor read,
# because the first pas2js on PATH is now the pinned one on every target.
$pinnedPas2js = @('deps/pas2js/bin', 'deps/pas2js-linux/bin',
    'deps/pas2js-darwin/bin') |
    ForEach-Object { Join-Path $repoRoot $_ } |
    Where-Object { Test-Path -LiteralPath $_ }
if ($pinnedPas2js.Count -gt 0) {
    $env:PATH = (($pinnedPas2js -join [System.IO.Path]::PathSeparator) +
        [System.IO.Path]::PathSeparator + $env:PATH)
    Write-Host ("[CAP-10B2] pinned pas2js on PATH: " +
        ($pinnedPas2js -join ', '))
} else {
    Write-Host ('[CAP-10B2] no pinned pas2js checkout found under deps/ -- ' +
        'the doctor row will report whatever the host carries')
}

$rows = [ordered]@{}
$failures = New-Object System.Collections.Generic.List[string]
function Row([string]$Name, $Value) { $rows[$Name] = $Value }
function Require([bool]$Ok, [string]$What) {
    if (-not $Ok) { $failures.Add($What) }
}
function Sha256Text([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha.ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($Text)) |
            ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}
function Sha256File([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
# ORDINAL, never Sort-Object. PowerShell's default sort is culture-aware and
# case-insensitive, so `App.tsx` and `app.css` order one way here and the
# other way under the bytewise `LC_ALL=C sort` the POSIX scripts use - and a
# digest whose ORDER depends on the runner's culture is a digest four targets
# can never agree on for a reason that has nothing to do with the bytes it
# was meant to measure. MEASURED on hosted run 33126638202.
function SortOrdinal([string[]]$Items) {
    $copy = [string[]]::new($Items.Length)
    [Array]::Copy($Items, $copy, $Items.Length)
    [Array]::Sort($copy, [System.StringComparer]::Ordinal)
    return $copy
}
# Pascal with comments removed, and with the placeholder tokens neutralised
# first - see check_cap10b2_contracts.ps1 for why that substitution is
# load-bearing. Here it costs nothing (a GENERATED project has no tokens
# left) and it keeps the two implementations of one projection identical.
function CodeText([string]$Path) {
    $text = [regex]::Replace([System.IO.File]::ReadAllText($Path),
        '\{\{[A-Z_]+\}\}', 'PWEBTOKEN')
    $out = New-Object System.Collections.Generic.List[string]
    $inBrace = $false
    $inParen = $false
    foreach ($line in ($text -split "`r?`n")) {
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
        if ($kept.Trim() -ne '') { $out.Add($kept.TrimEnd()) }
    }
    return (($out -join "`n") + "`n")
}
# the inventory projection, identical to the CAP-10B1 one so the React
# digest recomputed here is comparable to the closure value byte for byte
function InventoryOf([string]$Root) {
    $lines = New-Object System.Collections.Generic.List[string]
    $total = 0
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($Root.Length + 1).Replace('\', '/')
        $lines.Add("$rel $($f.Length) $(Sha256File $f.FullName)")
        $total += $f.Length
    }
    $sorted = SortOrdinal $lines.ToArray()
    return [pscustomobject]@{
        Text = (($sorted -join "`n") + "`n")
        Count = $sorted.Count
        Bytes = $total
    }
}

$capture = Join-Path $work 'capture'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $capture
New-Item -ItemType Directory -Force $capture | Out-Null
# every CLI leg runs the REAL executable, from an explicit working directory,
# with an argument ARRAY - there is no command string anywhere in this gate,
# so there is no grammar for a value to escape from
function RunCli([string]$Exe, [string]$WorkDir, [string[]]$CliArgs) {
    $so = Join-Path $capture 'stdout.txt'
    $se = Join-Path $capture 'stderr.txt'
    $p = Start-PWebProcess -FilePath $Exe -ArgumentList $CliArgs -Wait -PassThru `
        -NoNewWindow -WorkingDirectory $WorkDir `
        -RedirectStandardOutput $so -RedirectStandardError $se
    return [pscustomobject]@{
        Code = $p.ExitCode
        Out = [System.IO.File]::ReadAllText($so)
        Err = [System.IO.File]::ReadAllText($se)
    }
}

$bundle = 'com.example.demo'

# --- 1. the advertised surface, read back out of the help ------------------
$createHelp = RunCli $pweb $repoRoot @('create', '--help')
Require ($createHelp.Code -eq 0) 'create --help did not exit 0'
$advertised = ''
foreach ($line in ($createHelp.Out -split "`n")) {
    if ($line -match 'This build supports:\s*(.+?)\s*$') {
        $advertised = $Matches[1]
    }
}
$supported = (SortOrdinal @($advertised -split '\|')) -join ','
Require ($supported -ceq 'pas2js,react') `
    "create --help advertises '$advertised', expected 'react|pas2js'"
# and a name that must NOT be a command (`run` exists since CAP-10C0, `dev`
# since CAP-10C2 and `build` since CAP-10D0, so the subject of this leg moved
# to a name no shard will ratify - the claim is a CLOSED command set, and it
# survives the shard that emptied the old list)
foreach ($absent in 'publish') {
    $r = RunCli $pweb $repoRoot @($absent)
    Require ($r.Code -eq 2) `
        "'pweb $absent' must be an unknown command (exit 2), got $($r.Code)"
    Require ($r.Err.Contains('unknown_command')) `
        "'pweb $absent' did not refuse as unknown_command"
}

# --- 2. the refusal matrix -------------------------------------------------
$sandbox = Join-Path $work 'sandbox'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $sandbox
New-Item -ItemType Directory -Force $sandbox | Out-Null

$refusals = 0
function MustRefuse([string]$Tag, [string]$Exe, [string]$WorkDir,
                    [string[]]$CliArgs, [int]$Expected, [string]$Cause) {
    $r = RunCli $Exe $WorkDir $CliArgs
    $okCode = $r.Code -eq $Expected
    $okCause = $r.Err.Contains($Cause)
    Require $okCode "$Tag : expected exit $Expected, got $($r.Code)"
    Require $okCause "$Tag : the refusal did not name '$Cause': $($r.Err.Trim())"
    Require ($r.Out -eq '') "$Tag : a refusal wrote to stdout"
    if ($okCode -and $okCause) { $script:refusals++ }
    Write-Host "[CAP-10B2] refusal $Tag : exit=$($r.Code) $($r.Err.Trim() -split "`n" | Select-Object -First 1)"
}

# the vocabulary is EXACT and it is the parser's, not a template lookup's:
# a case variant, an abbreviation and a plausible alias are all just wrong
foreach ($bad in 'PAS2JS', 'Pas2js', 'pas2JS', 'p2js', 'pas', 'js') {
    MustRefuse "ui-$bad" $pweb $sandbox `
        @('create', 'demo', '--ui', $bad, '--bundle-id', $bundle) 2 'unsupported_ui'
}
MustRefuse 'duplicate-ui' $pweb $sandbox `
    @('create', 'demo', '--ui', 'pas2js', '--ui', 'pas2js', '--bundle-id', $bundle) 2 'duplicate_option'
MustRefuse 'ui-with-project' $pweb $sandbox `
    @('create', 'demo', '--ui', 'pas2js', '--bundle-id', $bundle, '--project', '.') 2 'option_not_for_command'
MustRefuse 'invalid-name' $pweb $sandbox `
    @('create', 'My-App', '--ui', 'pas2js', '--bundle-id', $bundle) 2 'invalid_name'

# a broken INSTALLATION is an environment failure, and CAP-10B2 adds the
# third shape to CAP-10B1's two: a pack that is missing, a pack the compiled
# registry does not describe, and a registry that does not describe a
# template this build advertises.
$sdkNoPack = Join-Path $work 'sdk-nopack'
$sdkBadPack = Join-Path $work 'sdk-badpack'
foreach ($d in $sdkNoPack, $sdkBadPack) {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $d
    New-Item -ItemType Directory -Force (Join-Path $d 'bin') | Out-Null
    Copy-Item -LiteralPath $pweb -Destination (Join-Path $d "bin/pweb$exeSuffix")
}
New-Item -ItemType Directory -Force (Join-Path $sdkBadPack 'share/pweb') | Out-Null
$badPack = Join-Path $sdkBadPack 'share/pweb/pweb-templates.zip'
Copy-Item -LiteralPath $pack -Destination $badPack
Add-Content -LiteralPath $badPack -Value 'x' -NoNewLine
MustRefuse 'pack-missing' (Join-Path $sdkNoPack "bin/pweb$exeSuffix") $sandbox `
    @('create', 'demo', '--ui', 'pas2js', '--bundle-id', $bundle) 4 'sdk_share_missing'
MustRefuse 'pack-tampered' (Join-Path $sdkBadPack "bin/pweb$exeSuffix") $sandbox `
    @('create', 'demo', '--ui', 'pas2js', '--bundle-id', $bundle) 4 'pack_size'
# THE ONE THAT MOVED. This executable's compiled registry describes react and
# nothing else, so `--ui pas2js` passes the parser's allowlist and then finds
# no template - which under CAP-10B2 is an installation fact, not a typo.
MustRefuse 'template-unknown' $reactOnly $sandbox `
    @('create', 'demo', '--ui', 'pas2js', '--bundle-id', $bundle) 4 'template_unknown'
# and that same executable still creates a react project, so the leg above
# measures the missing TEMPLATE rather than a broken build
$reactOnlyOk = Join-Path $work 'react-only-check'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $reactOnlyOk
New-Item -ItemType Directory -Force $reactOnlyOk | Out-Null
$r = RunCli $reactOnly $reactOnlyOk @('create', 'demo', '--ui', 'react', '--bundle-id', $bundle)
Require ($r.Code -eq 0) `
    ('the react-only CLI cannot create a react project either, so the ' +
     "template_unknown leg proves nothing: $($r.Err.Trim())")

# THE DESTINATION ARM, exercised end to end for the first time. Every
# transaction refusal maps to exit 3, and CAP-10B0 proved the transaction
# itself in-process against a synthetic plan - but no gate had ever watched
# `ExitForCreateRefusal` turn one into a process exit code on the real CLI.
# Creating the same project twice is the smallest line that does it, and it
# also proves the second attempt changed nothing: the tree the FIRST create
# produced is digested before and after.
$twice = Join-Path $work 'twice'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $twice
New-Item -ItemType Directory -Force $twice | Out-Null
$first = RunCli $pweb $twice @('create', 'demo', '--ui', 'pas2js', '--bundle-id', $bundle)
Require ($first.Code -eq 0) "the first create failed: $($first.Err.Trim())"
$beforeSecond = InventoryOf (Join-Path $twice 'demo')
MustRefuse 'destination-exists' $pweb $twice `
    @('create', 'demo', '--ui', 'pas2js', '--bundle-id', $bundle) 3 'destination_exists'
$afterSecond = InventoryOf (Join-Path $twice 'demo')
Require ($afterSecond.Text -ceq $beforeSecond.Text) `
    'the refused second create modified the project the first one produced'

Row 'pas2js_create_refusals' $refusals
$expectedRefusals = 13
Require ($refusals -eq $expectedRefusals) `
    "expected $expectedRefusals proven refusals, observed $refusals"

# NOT ONE of them may have left anything behind
$leftovers = @(Get-ChildItem -LiteralPath $sandbox -Force -ErrorAction SilentlyContinue)
Require ($leftovers.Count -eq 0) `
    "a refusal left $($leftovers.Count) entries in the destination parent"
Row 'pas2js_no_partial' $(if ($leftovers.Count -eq 0) { 'PASS' } else { 'FAIL' })

# --- 3. the real creations, from three different working directories -------
$roots = [ordered]@{
    plain = Join-Path $work 'cwd/plain'
    spaced = Join-Path $work 'cwd/with space'
    unicode = Join-Path $work ([char]0x00E9 + 'cwd')
}
$inventories = [ordered]@{}
foreach ($name in $roots.Keys) {
    $root = $roots[$name]
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $root
    New-Item -ItemType Directory -Force $root | Out-Null
    $r = RunCli $pweb $root @('create', 'demo', '--ui', 'pas2js', '--bundle-id', $bundle)
    Require ($r.Code -eq 0) "pas2js create from '$name' failed: $($r.Err.Trim())"
    Require ($r.Err -eq '') "pas2js create from '$name' wrote to stderr"
    Require (-not $r.Out.Contains([char]27)) `
        "pas2js create from '$name' emitted an ANSI escape"
    if ($name -eq 'plain') {
        Row 'pas2js_create_stdout_digest' (Sha256Text ($r.Out.Replace("`r`n", "`n")))
        # the report names the kind it produced, and it comes from the
        # TEMPLATE's declared ui rather than from the option that selected it
        Require ($r.Out -match '(?m)^\s*ui\s+pas2js\s*$') `
            'the create report does not name pas2js as the ui'
    }
    $inventories[$name] = InventoryOf (Join-Path $root 'demo')
}
$reference = $inventories['plain']
foreach ($name in 'spaced', 'unicode') {
    Require ($inventories[$name].Text -ceq $reference.Text) `
        "the pas2js project created from '$name' is not byte-identical to the plain one"
}
Row 'pas2js_generated_inventory_digest' (Sha256Text $reference.Text)
Row 'pas2js_generated_file_count' $reference.Count
Row 'pas2js_generated_total_bytes' $reference.Bytes
Row 'pas2js_create_deterministic' $(
    if (($inventories['spaced'].Text -ceq $reference.Text) -and
        ($inventories['unicode'].Text -ceq $reference.Text)) { 'PASS' }
    else { 'FAIL' })

# --- 4. the EXACT generated set, in both directions ------------------------
$expected = SortOrdinal @(
    '.gitattributes'
    '.gitignore'
    'README.md'
    'frontend/app.css'
    'frontend/index.html'
    'frontend/pas2js.cfg'
    'frontend/src/app.pas'
    'frontend/src/demoapp.lpr'
    'pweb.json'
    'src/app.services.pas'
    'src/demo.lpr'
)
$observed = SortOrdinal @(($reference.Text.TrimEnd("`n") -split "`n") |
    ForEach-Object { ($_ -split ' ')[0] })
Require ((($expected -join '|')) -ceq (($observed -join '|'))) `
    ("the generated pas2js set is not exact: expected $($expected -join ', ') " +
     "observed $($observed -join ', ')")
Row 'pas2js_generated_inventory_exact' $(
    if ((($expected -join '|')) -ceq (($observed -join '|'))) { 'PASS' }
    else { 'FAIL' })

$p2jProject = Join-Path $roots['plain'] 'demo'
Row 'pas2js_pweb_json_digest' (Sha256File (Join-Path $p2jProject 'pweb.json'))
Row 'pas2js_frontend_source_digest' (Sha256Text (
    (SortOrdinal @('frontend/index.html', 'frontend/app.css',
        'frontend/pas2js.cfg', 'frontend/src/app.pas',
        'frontend/src/demoapp.lpr') |
        ForEach-Object { "$_ $(Sha256File (Join-Path $p2jProject $_))" }) -join "`n"))

# No generated BYTE may name a host path, a home directory, this checkout or
# a CR.
$hostPathHits = 0
foreach ($f in (Get-ChildItem -LiteralPath $p2jProject -Recurse -File -Force)) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    foreach ($needle in '/Users/', '/home/', '\Users\', '%USERPROFILE%',
                        '$HOME', '\\?\', '/private/var/folders/', $repoRoot) {
        if ($text.Contains($needle)) {
            $hostPathHits++
            Require $false "$($f.Name) carries a host path: $needle"
        }
    }
    if ($text.Contains("`r")) {
        $hostPathHits++
        Require $false "$($f.Name) carries a CR byte"
    }
}
Row 'pas2js_generated_no_host_path' $(
    if ($hostPathHits -eq 0) { 'PASS' } else { 'FAIL' })

# --- 5. the React project, and the CLOSURE value it must still produce -----
$reactRoot = Join-Path $work 'cwd/react'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $reactRoot
New-Item -ItemType Directory -Force $reactRoot | Out-Null
$r = RunCli $pweb $reactRoot @('create', 'demo', '--ui', 'react', '--bundle-id', $bundle)
Require ($r.Code -eq 0) "react create failed: $($r.Err.Trim())"
$reactProject = Join-Path $reactRoot 'demo'
$reactInv = InventoryOf $reactProject
$reactDigest = Sha256Text $reactInv.Text
Require ($reactDigest -ceq $CAP10B1_REACT_INVENTORY_DIGEST) `
    ("the React project drifted: $reactDigest, CAP-10B1 closed on " +
     "$CAP10B1_REACT_INVENTORY_DIGEST")
Require ($reactInv.Count -eq $CAP10B1_REACT_FILE_COUNT) `
    "the React project has $($reactInv.Count) files, CAP-10B1 closed on $CAP10B1_REACT_FILE_COUNT"
Require ($reactInv.Bytes -eq $CAP10B1_REACT_TOTAL_BYTES) `
    "the React project is $($reactInv.Bytes) bytes, CAP-10B1 closed on $CAP10B1_REACT_TOTAL_BYTES"
Row 'react_generated_inventory_digest' $reactDigest
Row 'react_regression_result' $(
    if (($reactDigest -ceq $CAP10B1_REACT_INVENTORY_DIGEST) -and
        ($reactInv.Count -eq $CAP10B1_REACT_FILE_COUNT) -and
        ($reactInv.Bytes -eq $CAP10B1_REACT_TOTAL_BYTES)) { 'PASS' }
    else { 'FAIL' })

# --- 6. ONE generated native application, measured on the PROJECTS ---------
#
# check_cap10b2_contracts measures the TEMPLATES. This measures what a
# developer actually receives, after rendering, on this target - which is
# where a placeholder that resolved differently for one UI would show up.
$parityFailures = $failures.Count
foreach ($f in 'src/app.services.pas', '.gitattributes') {
    $a = Sha256File (Join-Path $reactProject $f)
    $b = Sha256File (Join-Path $p2jProject $f)
    Require ($a -ceq $b) `
        "$f differs between the generated react and pas2js projects"
}
# CAP-10C2: the React program now carries a PWEB_DEV region - the ONE place
# a build's mode is selected, and the reason `pweb dev` can compile a
# development host without the production one learning a single new name.
# The parity claim is unchanged and is about the PRODUCTION application, so
# the React program is reduced to its production form (every $ifdef PWEB_DEV
# body dropped, every $else body kept, the directives themselves removed)
# and THAT is what must equal the Pas2JS one byte for byte. Comparing the
# raw text instead would have made the claim "the two templates are the same
# file", which was never what it said.
function ProductionForm([string]$Text) {
    $out = New-Object System.Collections.Generic.List[string]
    $state = 'code'   # code | devbody | prodbody
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '\{\$ifdef\s+PWEB_DEV\}') { $state = 'devbody'; continue }
        if (($state -ne 'code') -and ($line -match '\{\$else\}')) {
            $state = 'prodbody'; continue
        }
        if (($state -ne 'code') -and ($line -match '\{\$endif\s+PWEB_DEV\}')) {
            $state = 'code'; continue
        }
        if ($state -eq 'devbody') { continue }
        $out.Add($line)
    }
    return ($out -join "`n")
}
# BOTH sides are reduced to production form, because BOTH carry the region.
# The development composition is frontend-AGNOSTIC - `PWebDevHostRun` takes an
# options record, a policy and a bridge and knows nothing about React - so
# putting it in one template and not the other would be the generated native
# host branching on frontend kind, which is the very thing this comparison
# exists to refuse. CAP-10C3 implements `pweb dev` for Pas2JS and inherits a
# generated program that already selects the development host.
$reactRaw = [System.IO.File]::ReadAllText((Join-Path $reactProject 'src/demo.lpr'))
$p2jRaw = [System.IO.File]::ReadAllText((Join-Path $p2jProject 'src/demo.lpr'))
$reactProd = Join-Path $work 'react-demo-production.lpr'
$p2jProd = Join-Path $work 'pas2js-demo-production.lpr'
[System.IO.File]::WriteAllText($reactProd, (ProductionForm $reactRaw),
    [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($p2jProd, (ProductionForm $p2jRaw),
    [System.Text.UTF8Encoding]::new($false))
$reactCode = CodeText $reactProd
$p2jCode = CodeText $p2jProd
Row 'react_dev_region_present' $(
    if ($reactRaw -match '\{\$ifdef\s+PWEB_DEV\}') { 'true' } else { 'false' })
Row 'pas2js_dev_region_present' $(
    if ($p2jRaw -match '\{\$ifdef\s+PWEB_DEV\}') { 'true' } else { 'false' })
Require ($reactRaw -match '\{\$ifdef\s+PWEB_DEV\}') `
    'the generated React program carries no PWEB_DEV region (CAP-10C2)'
Require ($p2jRaw -match '\{\$ifdef\s+PWEB_DEV\}') `
    ('the generated Pas2JS program carries no PWEB_DEV region -- the host ' +
     'composition must not branch on frontend kind (CAP-10C2)')
Require ($reactCode -ceq $p2jCode) `
    ('the generated src/demo.lpr differs in PRODUCTION code between the two ' +
     'UIs (the PWEB_DEV region is excluded by construction)')
Row 'shared_native_source_digest' (Sha256Text (
    $reactCode + (CodeText (Join-Path $reactProject 'src/app.services.pas'))))
# pweb.json differs in `ui` and in nothing else
$reactJson = ([System.IO.File]::ReadAllText(
    (Join-Path $reactProject 'pweb.json'))).Replace('"ui": "react"', '"ui": "UI"')
$p2jJson = ([System.IO.File]::ReadAllText(
    (Join-Path $p2jProject 'pweb.json'))).Replace('"ui": "pas2js"', '"ui": "UI"')
Require ($reactJson -ceq $p2jJson) `
    'the two generated pweb.json differ in more than the ui value'
Row 'native_parity' $(
    if ($failures.Count -eq $parityFailures) { 'PASS' } else { 'FAIL' })

# --- 7. the real doctor, on BOTH generated projects ------------------------
#
# WHAT IS ASSERTED HERE IS THE PROJECT, AND NOTHING ELSE - the CAP-10B1
# discipline, for the CAP-10B1 reason: `pweb doctor` answers two questions in
# one report, and only "what does this PROJECT declare" is this shard's to be
# judged on. The host rows are RECORDED.
function DoctorReport([string]$Root, [string]$Name) {
    $d = RunCli $pweb $Root @('doctor', '--project', $Name, '--json')
    return [pscustomobject]@{ Code = $d.Code; Report = ($d.Out | ConvertFrom-Json) }
}
function RequireRow($Report, [string]$Id, [string]$Status, [string]$Cause,
                    [string]$Where) {
    $row = @($Report.checks | Where-Object { $_.id -eq $Id })
    Require ($row.Count -eq 1) "doctor emitted no $Id row on the $Where project"
    if ($row.Count -eq 1) {
        Require ($row[0].status -eq $Status) `
            ("$Id is $($row[0].status)/$($row[0].cause) on the $Where " +
             "project, expected $Status")
        if ($Cause -ne '') {
            Require ($row[0].cause -ceq $Cause) `
                "$Id has cause $($row[0].cause) on the $Where project, expected $Cause"
        }
    }
    return $(if ($row.Count -eq 1) { $row[0] } else { $null })
}

$doctorFailures = $failures.Count
$p2jDoctor = DoctorReport $roots['plain'] 'demo'
foreach ($id in 'project.descriptor', 'project.native_program',
                'project.frontend_root', 'project.output') {
    RequireRow $p2jDoctor.Report $id 'pass' '' 'pas2js' | Out-Null
}
Require ("$($p2jDoctor.Report.project.ui)" -ceq 'pas2js') `
    "doctor reports ui = $($p2jDoctor.Report.project.ui) on the pas2js project"
Require ("$($p2jDoctor.Report.project.programIdent)" -ceq 'demo') `
    'doctor derived the wrong programIdent on the pas2js project'
# THE UI-AWARENESS CLAIM, asserted from the report: a Pas2JS project requires
# no Node, no npm and no lockfile, and each row says WHY rather than being
# quietly absent
foreach ($id in 'frontend.node', 'frontend.npm', 'frontend.lockfile',
                'frontend.dependencies') {
    RequireRow $p2jDoctor.Report $id 'not_applicable' 'ui_not_react' 'pas2js' |
        Out-Null
}
# and the row that IS its toolchain applies, with the pinned version
$p2jRow = RequireRow $p2jDoctor.Report 'frontend.pas2js' `
    $p2jDoctor.Report.checks.Where({ $_.id -eq 'frontend.pas2js' }).status `
    '' 'pas2js'
$p2jStatus = if ($null -ne $p2jRow) { "$($p2jRow.status)" } else { 'absent' }
$p2jObserved = if ($null -ne $p2jRow) { "$($p2jRow.observed)" } else { '' }
Require ($p2jStatus -ne 'not_applicable') `
    ('frontend.pas2js is not_applicable on a PAS2JS project -- the doctor ' +
     'is not UI-aware in the direction that matters')
Require ($p2jStatus -ne 'fail') `
    ("frontend.pas2js is fail/$(if ($null -ne $p2jRow) { $p2jRow.cause }) on " +
     'the pas2js project -- the pinned compiler must be findable, and this ' +
     'gate put it on PATH')
# the version the DOCTOR read, asserted rather than recorded: the pin is
# EXACT (a different Pas2JS is a different product, not a newer one), the
# gate put the pinned checkout first on PATH, and `tool_duplicated` says
# another install exists - never that the wrong one was measured
Require ($p2jObserved -ceq '3.0.1') `
    "doctor read Pas2JS '$p2jObserved' on the pas2js project, expected 3.0.1"
Row 'pas2js_doctor_row' "$p2jStatus/$(if ($null -ne $p2jRow) { $p2jRow.cause } else { '' })"
Row 'pas2js_doctor_version' $p2jObserved

$reactDoctor = DoctorReport $reactRoot 'demo'
foreach ($id in 'project.descriptor', 'project.native_program',
                'project.frontend_root', 'project.output', 'frontend.lockfile') {
    RequireRow $reactDoctor.Report $id 'pass' '' 'react' | Out-Null
}
Require ("$($reactDoctor.Report.project.ui)" -ceq 'react') `
    "doctor reports ui = $($reactDoctor.Report.project.ui) on the react project"
# the mirror rule: a React project does not need Pas2JS
RequireRow $reactDoctor.Report 'frontend.pas2js' 'not_applicable' `
    'ui_not_pas2js' 'react' | Out-Null
Row 'pas2js_doctor_result' $(
    if ($failures.Count -eq $doctorFailures) { 'PASS' } else { 'FAIL' })
# recorded, never compared and never a verdict
foreach ($pair in @(@('pas2js', $p2jDoctor), @('react', $reactDoctor))) {
    $hostFails = SortOrdinal @($pair[1].Report.checks |
        Where-Object { $_.status -eq 'fail' } |
        ForEach-Object { "$($_.id)/$($_.cause)" })
    Row "doctor_host_failures_$($pair[0])" ($hostFails -join ',')
    Row "doctor_exit_$($pair[0])" $pair[1].Code
    if ($hostFails.Count -gt 0) {
        Write-Host ("[CAP-10B2] doctor host observations on the $($pair[0]) " +
            "project (recorded, not gated): $($hostFails -join ', ')")
    }
}

# --- 8. the reference projects, left where prove_cap10b2 will find them ----
$projectRoot = Join-Path $work 'project'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $projectRoot
New-Item -ItemType Directory -Force $projectRoot | Out-Null
Copy-Item -Recurse -LiteralPath $p2jProject -Destination (Join-Path $projectRoot 'demo')
[System.IO.File]::WriteAllText((Join-Path $work 'generated-inventory.txt'),
    $reference.Text, [System.Text.UTF8Encoding]::new($false))

# --- 9. the verdict and the evidence ---------------------------------------
Row 'supported_uis' $supported
Row 'target' $target
Row 'pas2js_create_corpus' $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
$evidence = Join-Path $work "cli-$target.json"
[System.IO.File]::WriteAllText($evidence,
    (($rows | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host "[CAP-10B2] evidence: $evidence"
Write-Host ($rows | ConvertTo-Json -Depth 6)

if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Host "GATE FAILURE: $f" }
    throw "CAP-10B2 gates FAILED: $($failures.Count) failure(s)"
}
Write-Host "[CAP-10B2] pas2js create gates PASS on $target"
