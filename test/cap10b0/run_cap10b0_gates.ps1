# CAP-10B0: run the scaffold-engine gates and emit this target's evidence.
#
# ONE script for all four targets. Nothing here is platform-specific: the
# suite is headless, the builder needs no display, and pwsh is present on
# every runner this project uses. A bash twin would be a second
# implementation of a verifier, which is exactly what this repository
# avoids.
#
# WHAT IT PROVES, beyond running the suite:
#
#   - THE PACK IS A PURE FUNCTION of the trusted source. It is rebuilt into
#     a second path and the archive bytes AND the generated registry text
#     must be identical. Determinism proved by rebuilding is determinism;
#     determinism proved by reading the writer is a code review;
#
#   - THE BUILDER'S REFUSALS ARE REAL. Seven deliberately broken template
#     sources are staged - a link in the tree, an undeclared file, a
#     declared file that is missing, a CRLF text template, an output that
#     names a credential, a host path baked into a file, and a visibility
#     filter that selects nothing - and each must fail with its own
#     diagnostic. A refusal nobody has watched fire is a comment;
#
#   - THE ENGINE IS REACHABLE, AND NOTHING ELSE IS. CAP-10B0 asserted here
#     that `pweb create` did not exist; CAP-10B1 exposes it, so the leg is
#     INVERTED rather than removed - create must be advertised and must
#     refuse a missing NAME as a usage error, while `dev`, `run` and `build`
#     must still be absent from the help. The full create matrix belongs to
#     CAP-10B1; what stays here is that the engine this shard froze is
#     reachable at all, and that nothing else became reachable with it;
#
#   - THE ENGINE IS OFFLINE. The counts come from
#     check_cap10b0_contracts.ps1, which measures them over the compiled
#     unit set and the source, rather than being asserted here beside them.
#
# Emits build/cap10b0/tpl-<target>.json, which the CAP-7F emitter folds into
# this target's evidence.
#
# Usage: pwsh test/cap10b0/run_cap10b0_gates.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$work = Join-Path $repoRoot 'build/cap10b0'
$builder = Join-Path $work "bin/pwebtemplates$exeSuffix"
$suite = Join-Path $work "sdk/bin/tpltests$exeSuffix"
$pack = Join-Path $work 'sdk/share/pweb/pweb-templates.zip'
$registry = Join-Path $work 'gen/pweb.templates.registry.inc'
foreach ($pre in $builder, $suite, $pack, $registry) {
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
Write-Host "[CAP-10B0] target: $target"

$rows = [ordered]@{}
$failures = New-Object System.Collections.Generic.List[string]
function Row([string]$Name, $Value) { $rows[$Name] = $Value }
function Require([bool]$Ok, [string]$What) {
    if (-not $Ok) { $failures.Add($What) }
}

function Sha256Bytes([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# LF-normalized, so a digest is a digest of CONTENT and not of a checkout's
# line-ending policy
function Sha256Text([string]$Path) {
    $t = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha.ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($t)) |
            ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}

# --- 1. the headless suite -------------------------------------------------
$suiteLog = Join-Path $work 'tpltests.log'
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $work 'tpl-corpus.txt')
# /noenter is the WINDOWS switch that skips mormot.core.test's interactive
# ENTER wait; the POSIX runner has no such wait and REFUSES the option
if ($IsWindows) { $out = & $suite /noenter 2>&1 | Out-String }
else { $out = & $suite 2>&1 | Out-String }
$suiteCode = $LASTEXITCODE
[System.IO.File]::WriteAllText($suiteLog, $out)
Write-Host $out
Require ($suiteCode -eq 0) 'the CAP-10B0 suite failed'
# an exit code alone cannot tell "all passed" from "never ran": the five
# case headers must be present, the same rule the CAP-8/CAP-10A gates apply
foreach ($anchor in 'P web tpl pack', 'P web tpl render', 'P web tpl plan',
                    'P web tpl atomic', 'P web tpl security') {
    Require ($out.Contains($anchor)) "the suite never registered '$anchor'"
}
Row 'tpl_suite' $(if ($suiteCode -eq 0) { 'PASS' } else { 'FAIL' })

$corpusPath = Join-Path $work 'tpl-corpus.txt'
Require (Test-Path -LiteralPath $corpusPath) 'the suite emitted no corpus'
if (Test-Path -LiteralPath $corpusPath) {
    Row 'template_digest' (Sha256Text $corpusPath)
    Row 'template_corpus_lines' (
        @([System.IO.File]::ReadAllLines($corpusPath) |
          Where-Object { $_ -notmatch '^#' }).Count)
} else {
    Row 'template_digest' ''
    Row 'template_corpus_lines' 0
}

# --- 2. the pack is a pure function of its source --------------------------
$rebuildDir = Join-Path $work 'rebuild'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $rebuildDir
New-Item -ItemType Directory -Force $rebuildDir | Out-Null
$pack2 = Join-Path $rebuildDir 'pweb-templates.zip'
$registry2 = Join-Path $rebuildDir 'pweb.templates.registry.inc'
& $builder --source tools/templates --pack $pack2 --registry $registry2 `
    --include all | Out-Null
Require ($LASTEXITCODE -eq 0) 'the deterministic rebuild FAILED to run'
$packSha = Sha256Bytes $pack
$packSha2 = Sha256Bytes $pack2
Require ($packSha -ceq $packSha2) `
    "the pack is not deterministic: $packSha vs $packSha2"
$regSha = Sha256Text $registry
$regSha2 = Sha256Text $registry2
Require ($regSha -ceq $regSha2) 'the generated registry is not deterministic'
Row 'template_pack_digest' $packSha
Row 'template_pack_bytes' ((Get-Item -LiteralPath $pack).Length)
Row 'template_registry_digest' $regSha
Row 'template_deterministic' $(
    if (($packSha -ceq $packSha2) -and ($regSha -ceq $regSha2)) { 'PASS' }
    else { 'FAIL' })

# the semantic fields the builder itself reports, parsed back so the
# evidence carries what the BUILDER said rather than what this script
# recomputed
$summary = & $builder --source tools/templates --pack $pack2 `
    --registry $registry2 --include all 2>&1 | Out-String
foreach ($line in ($summary -split "`n")) {
    $parts = $line.Trim() -split ' ', 2
    if ($parts.Count -eq 2) {
        switch ($parts[0]) {
            'pack_schema'      { Row 'template_pack_schema' $parts[1].Trim() }
            'inventory_digest' { Row 'template_semantic_digest' $parts[1].Trim() }
            'templates'        { Row 'template_count' $parts[1].Trim() }
            'files'            { Row 'template_file_count' $parts[1].Trim() }
        }
    }
}
Require ("$($rows['template_pack_schema'])" -ceq '1') `
    'the template pack schema is not 1'

# --- 3. the builder's refusals, on deliberately broken sources -------------
# each case stages a COPY of the trusted source, breaks exactly one thing,
# and requires the builder to fail with its own diagnostic
$badRoot = Join-Path $work 'bad'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $badRoot
New-Item -ItemType Directory -Force $badRoot | Out-Null

function StageSource([string]$Tag) {
    $dst = Join-Path $badRoot $Tag
    Copy-Item -Recurse -Force (Join-Path $repoRoot 'tools/templates') $dst
    return $dst
}
function WriteLf([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"),
        [System.Text.UTF8Encoding]::new($false))
}
$refusals = 0
function MustRefuse([string]$Tag, [string]$Source, [string]$Fragment,
                    [string]$IncludeWhat = 'all') {
    $o = Join-Path $badRoot "$Tag.zip"
    $r = Join-Path $badRoot "$Tag.inc"
    $text = & $builder --source $Source --pack $o --registry $r `
        --include $IncludeWhat 2>&1 | Out-String
    $code = $LASTEXITCODE
    Require ($code -ne 0) "the builder ACCEPTED a broken source: $Tag"
    Require ($text -match [regex]::Escape($Fragment)) `
        "the $Tag refusal did not name '$Fragment': $($text.Trim())"
    Require (-not (Test-Path -LiteralPath $o)) `
        "the builder wrote a pack for the broken source: $Tag"
    if (($code -ne 0) -and ($text -match [regex]::Escape($Fragment))) {
        $script:refusals++
    }
    Write-Host "[CAP-10B0] refusal $Tag : $($text.Trim())"
}

# B1: a reparse point inside the template tree. Trusted build input is READ,
# never followed - and the fixture is a REAL link on every platform
$src = StageSource 'link'
$linkPath = Join-Path $src 'fixture/linked'
$linkTarget = Join-Path $src 'fixture/frontend'
$linkMade = $false
try {
    if ($IsWindows) {
        New-Item -ItemType Junction -Path $linkPath -Target $linkTarget `
            -ErrorAction Stop | Out-Null
    } else {
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $linkTarget `
            -ErrorAction Stop | Out-Null
    }
    $linkMade = $true
} catch {
    Require $false ("the link fixture could not be created: " +
        "$($_.Exception.Message) -- this gate refuses to record a link " +
        'rule it did not actually test')
}
if ($linkMade) { MustRefuse 'link' $src 'reparse point refused' }

# B2: a file on disk that the list does not declare
$src = StageSource 'undeclared'
WriteLf (Join-Path $src 'fixture/stowaway.txt') "unreviewed`n"
MustRefuse 'undeclared' $src 'undeclared file in the template source'

# B3: a declared file that is not on disk
$src = StageSource 'missing'
Remove-Item -Force (Join-Path $src 'fixture/README.md')
MustRefuse 'missing' $src 'declared file missing from the template source'

# B4: a CRLF text template. THE one that matters most: Git for Windows
# defaults to core.autocrlf=true, so this is the shape a bad checkout has
$src = StageSource 'crlf'
[System.IO.File]::WriteAllText((Join-Path $src 'fixture/README.md'),
    "# {{PROJECT_NAME}}`r`nline two`r`n",
    [System.Text.UTF8Encoding]::new($false))
MustRefuse 'crlf' $src 'entry_line_ending'

# B5: an output path that names a credential
$src = StageSource 'secret'
$list = [System.IO.File]::ReadAllText((Join-Path $src 'templates.list'))
WriteLf (Join-Path $src 'templates.list') `
    ($list.Replace('    out = README.md', '    out = .env'))
MustRefuse 'secret' $src 'entry_secret'

# B6: an absolute host path baked into a template
$src = StageSource 'hostpath'
WriteLf (Join-Path $src 'fixture/README.md') `
    ("# {{PROJECT_NAME}}`n`nthe sdk lives in C:\Users\somebody\pweb`n")
MustRefuse 'hostpath' $src 'entry_host_path'

# B7: a visibility filter that selects nothing. An empty pack must be a
# REFUSAL rather than a zero-entry archive somebody later has to explain.
#
# CAP-10B1 CHANGED HOW THIS LEG IS STAGED, and the change is worth naming.
# CAP-10B0 shipped one PRIVATE fixture, so `--include public` selected
# nothing on the unmodified source and the leg needed no mutation at all.
# The react template is public, so the empty selection now has to be
# CONSTRUCTED - by making every template private in the staged copy - which
# is what the other six legs already do. The rule under test is unchanged;
# only the shape of the source that reaches it is.
$src = StageSource 'visibility'
$list = [System.IO.File]::ReadAllText((Join-Path $src 'templates.list'))
WriteLf (Join-Path $src 'templates.list') `
    ($list.Replace('  visibility = public', '  visibility = private'))
MustRefuse 'visibility' $src 'selected no template' 'public'

Row 'template_refusals' $refusals
Row 'template_source_gate' $(if ($refusals -eq 7) { 'PASS' } else { 'FAIL' })
Require ($refusals -eq 7) `
    "expected 7 builder refusals, observed $refusals"

# --- 4. the ENGINE's own command, measured on the REAL executable ----------
#
# CAP-10B0 asserted here that `pweb create` was an unknown command. CAP-10B1
# exposes it, so the leg is INVERTED rather than removed: create is now
# required to exist, and `dev`, `run` and `build` are still required not to.
# The full create matrix is CAP-10B1's (test/cap10b1/run_cap10b1_gates.ps1);
# what stays here is the one thing this shard owns - that the engine it
# froze is reachable at all, and that nothing ELSE became reachable with it.
$pweb = Join-Path $repoRoot "build/cap10a/bin/pweb$exeSuffix"
if (Test-Path -LiteralPath $pweb) {
    $so = Join-Path $work 'cli-stdout.txt'
    $se = Join-Path $work 'cli-stderr.txt'
    $p = Start-Process -FilePath $pweb -ArgumentList '--help' -Wait -PassThru `
        -NoNewWindow -RedirectStandardOutput $so -RedirectStandardError $se
    $help = [System.IO.File]::ReadAllText($so)
    Require ($p.ExitCode -eq 0) '--help did not exit 0'
    Require ($help.Contains('pweb create ')) `
        '--help does not advertise create'
    foreach ($absent in 'dev ', 'run ', 'build') {
        Require (-not $help.Contains("pweb $absent")) `
            "--help advertises an unimplemented command: $absent"
    }
    # a bare `pweb create` is a USAGE refusal (no NAME), never an unknown
    # command any more
    $p = Start-Process -FilePath $pweb -ArgumentList 'create' -Wait `
        -PassThru -NoNewWindow -RedirectStandardOutput $so `
        -RedirectStandardError $se
    $err = [System.IO.File]::ReadAllText($se)
    Require ($p.ExitCode -eq 2) `
        "'pweb create' with no NAME must be a usage error, got $($p.ExitCode)"
    Require ($err.Contains('missing_operand')) `
        "'pweb create' did not refuse as missing_operand: $($err.Trim())"
    Row 'create_present' 'PASS'
} else {
    Require $false ("build/cap10a/bin/pweb is absent -- the create-linkage " +
        'gate measures the REAL executable and cannot run without it')
    Row 'create_present' 'FAIL'
}

# --- 5. the offline proof, from the contracts check ------------------------
$contractsPath = Join-Path $work 'contracts.json'
Require (Test-Path -LiteralPath $contractsPath) `
    'contracts.json is absent -- run check_cap10b0_contracts.ps1 first'
if (Test-Path -LiteralPath $contractsPath) {
    $c = Get-Content -Raw -LiteralPath $contractsPath | ConvertFrom-Json
    Require ("$($c.create_linked)" -ceq 'linked') `
        "the scaffold engine is NOT linked into the CLI: $($c.create_linked)"
    Require ([int]$c.network_units -eq 0) 'the builder links a network unit'
    Require ([int]$c.process_apis -eq 0) 'the engine names a process API'
    Require ([int]$c.environment_reads -eq 0) 'the engine reads the environment'
    Require ([int]$c.cr_files -eq 0) 'a template source carries a CR byte'
    # the two counts the acceptance criteria name. They are DERIVED from the
    # mechanical proofs above rather than asserted: with no process API and
    # no networking unit anywhere in the engine, there is no code path a
    # call could take
    Row 'network_calls' 0
    Row 'package_manager_calls' 0
    Row 'template_sources' $c.template_sources
    Row 'template_offline' $(
        if (([int]$c.network_units -eq 0) -and
            ([int]$c.process_apis -eq 0) -and
            ([int]$c.environment_reads -eq 0)) { 'PASS' } else { 'FAIL' })
} else {
    Row 'network_calls' -1
    Row 'package_manager_calls' -1
    Row 'template_offline' 'FAIL'
}

# --- 6. the per-target OBSERVATION, recorded and never compared ------------
# file modes do not exist on Windows. That is a fact about the platform, so
# it travels here rather than in the corpus, exactly as the CAP-10A doctor
# observations do
Row 'template_modes_applicable' $(if ($IsWindows) { 'false' } else { 'true' })

# --- 7. the verdict and the evidence ---------------------------------------
Row 'target' $target
Row 'template_corpus' $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
$evidence = Join-Path $work "tpl-$target.json"
[System.IO.File]::WriteAllText($evidence,
    (($rows | ConvertTo-Json -Depth 6) + "`n"),
    [System.Text.UTF8Encoding]::new($false))
Write-Host "[CAP-10B0] evidence: $evidence"
Write-Host ($rows | ConvertTo-Json -Depth 6)

if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Host "GATE FAILURE: $f" }
    throw "CAP-10B0 gates FAILED: $($failures.Count) failure(s)"
}
Write-Host "[CAP-10B0] gates PASS on $target"
