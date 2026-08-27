# CAP-10B1: run the public-command gates against the REAL compiled CLI and
# emit this target's create evidence.
#
# ONE script for all four targets. Everything here is headless: no window,
# no display, no network and no package manager. The build proof and the
# real GUI run live in prove_cap10b1.ps1/.sh, because those genuinely need a
# toolchain and a desktop session and these gates must not.
#
# WHAT IT PROVES, and why each leg is a leg:
#
#   - THE COMMAND EXISTS AND SAYS WHAT IT DOES. `create` is in the global
#     help, `create --help` advertises exactly the frontend kinds the parser
#     accepts, and dev/run/build are still unknown commands. A help text and
#     a parser that disagree is how a CLI ends up promising a template
#     nobody shipped;
#
#   - THE REFUSALS ARE REAL AND CATEGORISED. Fourteen bad command lines and
#     two broken installations are executed, each required to produce its
#     own machine-stable cause AND the exit category the contract assigns
#     it. A refusal nobody has watched fire is a comment;
#
#   - NOTHING PARTIAL SURVIVES A FAILURE. Every refusal that could have
#     touched a filesystem is followed by an assertion that the destination
#     is absent;
#
#   - THE OUTPUT IS A FUNCTION OF THE INPUTS. The same project is created
#     from three different working directories - one ordinary, one whose
#     path contains a space, one whose path contains non-ASCII characters -
#     and all three trees must be byte-identical, which is what makes
#     `generated_inventory_digest` a four-target equality field rather than
#     a per-machine observation;
#
#   - THE PROJECT IS A PROJECT. The real `pweb doctor` is run against it and
#     must accept it, which closes the CAP-10B0 `frontend.lockfile`
#     limitation by measurement rather than by assertion.
#
# Emits build/cap10b1/cli-<target>.json and leaves the reference project at
# build/cap10b1/project/demo for prove_cap10b1 to relocate and build.
#
# Usage: pwsh test/cap10b1/run_cap10b1_gates.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$work = Join-Path $repoRoot 'build/cap10b1'
$pweb = Join-Path $work "sdk/bin/pweb$exeSuffix"
$pack = Join-Path $work 'sdk/share/pweb/pweb-templates.zip'
foreach ($pre in $pweb, $pack) {
    if (-not (Test-Path -LiteralPath $pre)) {
        throw "missing precondition: $pre -- run the build script first"
    }
}

if ($IsWindows) { $target = 'windows-x86_64' }
elseif ($IsLinux) { $target = 'linux-x86_64' }
elseif ($IsMacOS) {
    $target = if ((uname -m).Trim() -eq 'arm64') { 'macos-arm64' }
              else { 'macos-x86_64' }
} else { throw 'unsupported host' }
Write-Host "[CAP-10B1] target: $target"

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

# every CLI leg runs the REAL executable, from an explicit working
# directory, with an argument ARRAY - there is no command string anywhere in
# this gate, so there is no grammar for a value to escape from
$capture = Join-Path $work 'capture'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $capture
New-Item -ItemType Directory -Force $capture | Out-Null
function RunCli([string]$Exe, [string]$WorkDir, [string[]]$CliArgs) {
    $so = Join-Path $capture 'stdout.txt'
    $se = Join-Path $capture 'stderr.txt'
    $p = Start-Process -FilePath $Exe -ArgumentList $CliArgs -Wait -PassThru `
        -NoNewWindow -WorkingDirectory $WorkDir `
        -RedirectStandardOutput $so -RedirectStandardError $se
    return [pscustomobject]@{
        Code = $p.ExitCode
        Out = [System.IO.File]::ReadAllText($so)
        Err = [System.IO.File]::ReadAllText($se)
    }
}

# --- 1. the advertised surface --------------------------------------------
$help = RunCli $pweb $repoRoot @('--help')
Require ($help.Code -eq 0) '--help did not exit 0'
Require ($help.Out.Contains('pweb create NAME --ui react')) `
    'the global help does not advertise create'
foreach ($absent in 'pweb dev', 'pweb run', 'pweb build') {
    Require (-not $help.Out.Contains($absent)) `
        "the global help advertises an unimplemented command: $absent"
}
Row 'cli_create_available' $(if ($help.Out.Contains('pweb create NAME')) {
    'PASS' } else { 'FAIL' })

$createHelp = RunCli $pweb $repoRoot @('create', '--help')
Require ($createHelp.Code -eq 0) 'create --help did not exit 0'
Require ($createHelp.Out.Contains('This build supports: react')) `
    'create --help does not advertise react'
Require (-not $createHelp.Out.Contains('pas2js')) `
    'create --help advertises pas2js before CAP-10B2 exists'
Row 'create_help_digest' (Sha256Text ($createHelp.Out.Replace("`r`n", "`n")))
# the advertised set, read back OUT of the help text rather than restated
# here: a gate that asserts its own copy of the answer proves nothing
$advertised = ''
foreach ($line in ($createHelp.Out -split "`n")) {
    if ($line -match 'This build supports:\s*(.+?)\s*$') {
        $advertised = $Matches[1]
    }
}
Require ($advertised -ceq 'react') `
    "create --help advertises '$advertised', expected 'react'"
Row 'advertised_ui' $advertised

# dev/run/build must still be UNKNOWN COMMANDS, not merely unadvertised
foreach ($absent in 'dev', 'run', 'build') {
    $r = RunCli $pweb $repoRoot @($absent)
    Require ($r.Code -eq 2) `
        "'pweb $absent' must be an unknown command (exit 2), got $($r.Code)"
    Require ($r.Err.Contains('unknown_command')) `
        "'pweb $absent' did not refuse as unknown_command"
}

# --- 2. the refusal matrix, each with its cause AND its category ----------
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
    Write-Host "[CAP-10B1] refusal $Tag : exit=$($r.Code) $($r.Err.Trim() -split "`n" | Select-Object -First 1)"
}

$bundle = 'com.example.demo'
MustRefuse 'missing-name' $pweb $sandbox @('create', '--ui', 'react', '--bundle-id', $bundle) 2 'missing_operand'
MustRefuse 'invalid-name' $pweb $sandbox @('create', 'My-App', '--ui', 'react', '--bundle-id', $bundle) 2 'invalid_name'
MustRefuse 'missing-ui' $pweb $sandbox @('create', 'demo', '--bundle-id', $bundle) 2 'missing_option'
MustRefuse 'pas2js-ui' $pweb $sandbox @('create', 'demo', '--ui', 'pas2js', '--bundle-id', $bundle) 2 'unsupported_ui'
MustRefuse 'unknown-ui' $pweb $sandbox @('create', 'demo', '--ui', 'svelte', '--bundle-id', $bundle) 2 'unsupported_ui'
MustRefuse 'missing-bundle' $pweb $sandbox @('create', 'demo', '--ui', 'react') 2 'missing_option'
MustRefuse 'invalid-bundle' $pweb $sandbox @('create', 'demo', '--ui', 'react', '--bundle-id', 'NotADns') 2 'invalid_bundle_id'
MustRefuse 'duplicate-ui' $pweb $sandbox @('create', 'demo', '--ui', 'react', '--ui', 'react', '--bundle-id', $bundle) 2 'duplicate_option'
MustRefuse 'unknown-option' $pweb $sandbox @('create', 'demo', '--ui', 'react', '--bundle-id', $bundle, '--force') 2 'unknown_option'
MustRefuse 'extra-positional' $pweb $sandbox @('create', 'demo', 'extra', '--ui', 'react', '--bundle-id', $bundle) 2 'extra_positional'
MustRefuse 'project-on-create' $pweb $sandbox @('create', 'demo', '--ui', 'react', '--bundle-id', $bundle, '--project', '.') 2 'option_not_for_command'
MustRefuse 'empty-ui' $pweb $sandbox @('create', 'demo', '--ui=', '--bundle-id', $bundle) 2 'empty_value'
MustRefuse 'missing-value' $pweb $sandbox @('create', 'demo', '--ui', '--bundle-id', $bundle) 2 'missing_value'

# a broken INSTALLATION is an environment failure, and the two shapes are
# distinguished: no pack at all, and a pack the compiled registry does not
# describe. Both stage a real SDK root around a copy of the real executable.
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
# ONE appended byte: the length check fires before a hash is even needed,
# which is the verifier's own order and worth seeing hold
Add-Content -LiteralPath $badPack -Value 'x' -NoNewline
MustRefuse 'pack-missing' (Join-Path $sdkNoPack "bin/pweb$exeSuffix") $sandbox `
    @('create', 'demo', '--ui', 'react', '--bundle-id', $bundle) 4 'sdk_share_missing'
MustRefuse 'pack-tampered' (Join-Path $sdkBadPack "bin/pweb$exeSuffix") $sandbox `
    @('create', 'demo', '--ui', 'react', '--bundle-id', $bundle) 4 'pack_size'

Row 'create_refusals' $refusals
$expectedRefusals = 15
Require ($refusals -eq $expectedRefusals) `
    "expected $expectedRefusals proven refusals, observed $refusals"

# NOT ONE of them may have left anything behind
$leftovers = @(Get-ChildItem -LiteralPath $sandbox -Force -ErrorAction SilentlyContinue)
Require ($leftovers.Count -eq 0) `
    "a refusal left $($leftovers.Count) entries in the destination parent"
Row 'create_no_partial' $(if ($leftovers.Count -eq 0) { 'PASS' } else { 'FAIL' })

# --- 3. the real creations, from three different working directories ------
# one ordinary, one containing a space, one containing non-ASCII: the
# destination parent is the ONLY path input create has, so these three are
# the whole of its input space
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
    $r = RunCli $pweb $root @('create', 'demo', '--ui', 'react', '--bundle-id', $bundle)
    Require ($r.Code -eq 0) "create from '$name' failed: $($r.Err.Trim())"
    Require ($r.Err -eq '') "create from '$name' wrote to stderr"
    # a successful create emits NO ANSI on any stream, ever - there is no
    # terminal condition under which it would, which is why this is checked
    # rather than only checked when redirected
    Require (-not $r.Out.Contains([char]27)) `
        "create from '$name' emitted an ANSI escape"
    if ($name -eq 'plain') { Row 'create_stdout_digest' (Sha256Text ($r.Out.Replace("`r`n", "`n"))) }

    $project = Join-Path $root 'demo'
    $lines = New-Object System.Collections.Generic.List[string]
    $total = 0
    foreach ($f in (Get-ChildItem -LiteralPath $project -Recurse -File -Force |
                    Sort-Object { $_.FullName })) {
        $rel = $f.FullName.Substring($project.Length + 1).Replace('\', '/')
        $lines.Add("$rel $($f.Length) $(Sha256File $f.FullName)")
        $total += $f.Length
    }
    # sorted by the RELATIVE name, so a filesystem that walks in a different
    # order cannot change the digest
    $sorted = @($lines | Sort-Object)
    $inventories[$name] = [pscustomobject]@{
        Text = (($sorted -join "`n") + "`n")
        Count = $sorted.Count
        Bytes = $total
    }
}

$reference = $inventories['plain']
foreach ($name in 'spaced', 'unicode') {
    Require ($inventories[$name].Text -ceq $reference.Text) `
        "the project created from '$name' is not byte-identical to the plain one"
}
Row 'generated_inventory_digest' (Sha256Text $reference.Text)
Row 'generated_file_count' $reference.Count
Row 'generated_total_bytes' $reference.Bytes
Row 'create_deterministic' $(
    if (($inventories['spaced'].Text -ceq $reference.Text) -and
        ($inventories['unicode'].Text -ceq $reference.Text)) { 'PASS' }
    else { 'FAIL' })

# --- 4. the EXACT generated set, in both directions -----------------------
# named here in full and compared as a set: a project that grew a file and a
# project that lost one are both failures, and neither shows up in a count
$expected = @(
    '.gitattributes'
    '.gitignore'
    'README.md'
    'frontend/index.html'
    'frontend/package-lock.json'
    'frontend/package.json'
    'frontend/src/App.tsx'
    'frontend/src/app.css'
    'frontend/src/main.tsx'
    'frontend/src/vite-env.d.ts'
    'frontend/tsconfig.json'
    'frontend/vite.config.ts'
    'pweb.json'
    'src/app.services.pas'
    'src/demo.lpr'
) | Sort-Object
$observed = @(($reference.Text.TrimEnd("`n") -split "`n") |
    ForEach-Object { ($_ -split ' ')[0] }) | Sort-Object
Require ((($expected -join '|')) -ceq (($observed -join '|'))) `
    ("the generated set is not exact: expected $($expected -join ', ') " +
     "observed $($observed -join ', ')")
Row 'generated_inventory_exact' $(
    if ((($expected -join '|')) -ceq (($observed -join '|'))) { 'PASS' }
    else { 'FAIL' })

$project = Join-Path $roots['plain'] 'demo'
Row 'generated_pweb_json_digest' (Sha256File (Join-Path $project 'pweb.json'))
Row 'generated_package_lock_digest' `
    (Sha256File (Join-Path $project 'frontend/package-lock.json'))

# No generated BYTE may name a host path, a home directory, this checkout or
# a CR. Deliberately NOT swept for here: the string `node_modules`, which is
# legitimate content - a lockfile's package map is keyed by it and the
# generated .gitignore names it. Whether a node_modules TREE was generated
# is an inventory question, and the exact-set check above already answers it.
$hostPathHits = 0
foreach ($f in (Get-ChildItem -LiteralPath $project -Recurse -File -Force)) {
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
Row 'generated_no_host_path' $(if ($hostPathHits -eq 0) { 'PASS' } else { 'FAIL' })

# --- 5. the real doctor, against the project that was just created --------
$doctor = RunCli $pweb $roots['plain'] @('doctor', '--project', 'demo', '--json')
Require ($doctor.Code -eq 0) `
    "pweb doctor refused the generated project (exit $($doctor.Code))"
$report = $doctor.Out | ConvertFrom-Json
$failRows = @($report.checks | Where-Object { $_.status -eq 'fail' })
Require ($failRows.Count -eq 0) `
    ("doctor reported $($failRows.Count) failing rows: " +
     ($failRows | ForEach-Object { $_.id }) -join ', ')
$lockRow = @($report.checks | Where-Object { $_.id -eq 'frontend.lockfile' })
Require ($lockRow.Count -eq 1) 'doctor emitted no frontend.lockfile row'
if ($lockRow.Count -eq 1) {
    Require ($lockRow[0].status -eq 'pass') `
        ("frontend.lockfile is $($lockRow[0].status) -- the CAP-10B0 " +
         'limitation this template exists to close')
}
Require ("$($report.project.refusal)" -ceq 'ok') `
    "doctor reports project.refusal = $($report.project.refusal)"
Require ("$($report.project.name)" -ceq 'demo') 'doctor reports the wrong name'
Require ("$($report.project.bundleId)" -ceq $bundle) `
    'doctor reports the wrong bundle identifier'
Require ("$($report.project.ui)" -ceq 'react') 'doctor reports the wrong ui'
Row 'doctor_result' $(if ($doctor.Code -eq 0) { 'PASS' } else { 'FAIL' })
Row 'doctor_exit' $doctor.Code

# --- 6. the reference project, left where prove_cap10b1 will find it ------
$projectRoot = Join-Path $work 'project'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $projectRoot
New-Item -ItemType Directory -Force $projectRoot | Out-Null
Copy-Item -Recurse -LiteralPath $project -Destination (Join-Path $projectRoot 'demo')
[System.IO.File]::WriteAllText((Join-Path $work 'generated-inventory.txt'),
    $reference.Text, [System.Text.UTF8Encoding]::new($false))

# --- 7. the verdict and the evidence ---------------------------------------
Row 'target' $target
Row 'create_corpus' $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
$evidence = Join-Path $work "cli-$target.json"
[System.IO.File]::WriteAllText($evidence,
    (($rows | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host "[CAP-10B1] evidence: $evidence"
Write-Host ($rows | ConvertTo-Json -Depth 6)

if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Host "GATE FAILURE: $f" }
    throw "CAP-10B1 gates FAILED: $($failures.Count) failure(s)"
}
Write-Host "[CAP-10B1] create gates PASS on $target"
