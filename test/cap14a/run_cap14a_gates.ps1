# CAP-14A: the bundler refuses what the native CSP will not run.
#
# THE DEFECT, measured by an external reviewer and recorded as TODO.txt #2:
# a dist whose index.html carried an inline <script> packed cleanly,
# `--verify`d cleanly, built cleanly and then half-worked under
# PWEB_NATIVE_CSP (`script-src 'self'`, no 'unsafe-inline') with NO ERROR
# ANYWHERE. No engine reports a blocked inline script to the application, so
# the only place the truth can be told is the tool that packs the bundle.
#
# EVERY LEG DRIVES THE REAL BINARY. Nothing here reimplements a rule: the
# refusals come from the `pwebbundle` the SDK ships, the exit categories come
# from the real `pweb build`, and the development behaviour comes from a real
# `pweb dev` session on a project the real `pweb create` scaffolded.
#
#   C1  each refusal class, through the real bundler, on its own fixture
#   C2  each accept class, on a signage-shaped dist that must pack
#   C3  the two refusals to JUDGE - a UTF-16 document and an unterminated
#       raw-text element - built at runtime rather than committed as text
#   C4  one of each violation in ONE dist: every finding in one round
#   C5  every existing corpus still packs - the four example dists, the two
#       templates, the four test fixtures and whatever real Vite / Pas2JS
#       output this workspace carries
#   C6  a refusal writes nothing and leaves a previous output intact
#   C7  no ANSI reaches a redirected stream
#   C8  no override: the option surface is exactly the three ratified flags
#   C9  the digests four targets must agree on
#   B1  `pweb build` on a pas2js project that grew an inline script: exit 5,
#       the typed cause forwarded, NO release layout, the previous release
#       untouched
#   D1  `pweb dev` on the same project: the generation is refused, the
#       PREVIOUS generation stays live, the host is not restarted, and the
#       loop recovers when the document is fixed
#
# Emits build/cap14a/cli-<target>.json for the CAP-7F aggregation.
#
# Usage: pwsh test/cap14a/run_cap14a_gates.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

. (Join-Path $repoRoot 'test/cap10d0/psargs.ps1')

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$work = Join-Path $repoRoot 'build/cap14a'
New-Item -ItemType Directory -Force $work | Out-Null

$rows = [ordered]@{}
$failures = New-Object System.Collections.Generic.List[string]
function Row([string]$Key, [string]$Value) { $rows[$Key] = $Value }
function Require([bool]$Ok, [string]$Message) {
    if (-not $Ok) {
        $failures.Add($Message)
        Write-Host "GATE FAILURE: $Message"
    }
}
function Bool([bool]$B) { if ($B) { 'true' } else { 'false' } }
function Sha256Text([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $b = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($b)) `
            -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}
# A SOURCE DIGEST FOUR TARGETS CAN AGREE ON has to be normalised, because
# Pascal sources are not LF-pinned in .gitattributes (ledger 10E-4) and a
# Windows checkout may hold CRLF where a POSIX one holds LF. Normalising is
# what makes this a digest of the RULE rather than of the checkout.
function Sha256Lf([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    $t = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    return Sha256Text $t
}
function TargetName {
    $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64'   { 'x86_64' }
        'Arm64' { 'arm64' }
        default { 'other' }
    }
    return "$os-$arch"
}
# READ A FILE A LIVE PROCESS IS STILL WRITING - the CAP-10C2 lesson, copied
# from test/cap10c3: Start-Process -RedirectStandardError holds the file on
# Windows and ReadAllText throws a sharing violation while the child lives
function ReadLive([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = $null
    $sr = $null
    try {
        $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = [System.IO.StreamReader]::new($fs)
        return $sr.ReadToEnd()
    } catch {
        return ''
    } finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}

$target = TargetName
Row 'target' $target
Row 'csp_refusal_available' 'true'

# --- preconditions ----------------------------------------------------------
# THE SDK'S OWN BUNDLER, not a per-target build directory: it is the binary
# `pweb build` and `pweb dev` spawn, so all three families of leg below
# measure one executable rather than three that ought to agree.
$sdk = Join-Path $repoRoot 'build/cap10b1/sdk'
$bundler = Join-Path $sdk "bin/pwebbundle$exeSuffix"
$pweb = Join-Path $sdk "bin/pweb$exeSuffix"
foreach ($pre in $bundler, $pweb) {
    Require (Test-Path -LiteralPath $pre) `
        "precondition absent: $pre -- run the CAP-10B1 SDK staging first"
}
$fixtures = Join-Path $repoRoot 'test/cap14a/fixtures'
Require (Test-Path -LiteralPath $fixtures) 'the CAP-14A fixtures are absent'
if ($failures.Count -gt 0) {
    throw "CAP-14A preconditions FAILED: $($failures.Count)"
}

$scratch = Join-Path $work 'scratch'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $scratch
New-Item -ItemType Directory -Force $scratch | Out-Null

# one pack, through the real binary, with both streams captured
function Pack([string]$Dist, [string]$Out) {
    $so = Join-Path $scratch 'pack-stdout.txt'
    $se = Join-Path $scratch 'pack-stderr.txt'
    Remove-Item -Force -ErrorAction SilentlyContinue $so, $se
    $p = Start-PWebProcess -FilePath $bundler -ArgumentList @($Dist, $Out) `
        -Wait -PassThru -NoNewWindow -WorkingDirectory $repoRoot `
        -RedirectStandardOutput $so -RedirectStandardError $se
    $out = if (Test-Path -LiteralPath $so) { [System.IO.File]::ReadAllText($so) } else { '' }
    $err = if (Test-Path -LiteralPath $se) { [System.IO.File]::ReadAllText($se) } else { '' }
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $out; Err = $err }
}

# --- C0: the contract cross-checks, read back -------------------------------
# The source-level properties a gate driving binaries cannot see: one caller,
# four options, six causes, no second policy, and the CSP this whole shard is
# a claim about, unchanged.
$contractsFile = Join-Path $work 'contracts.json'
if (Test-Path -LiteralPath $contractsFile) {
    $contracts = Get-Content -Raw -LiteralPath $contractsFile | ConvertFrom-Json
    Row 'csp_contracts' "$($contracts.verdict)"
    Row 'csp_policy_callers' "$($contracts.policy_callers)"
    # `false` where a DEDICATED host unit directory exists to read, and
    # `not_applicable` where the leg's -FU directories are shared between the
    # bundler and the host - see check_cap14a_contracts.ps1. The four-target
    # invariant is csp_policy_callers, which is pinned and compared; this row
    # is the corroboration and is per-target by construction.
    Row 'csp_policy_unit_in_host' "$($contracts.policy_unit_in_host)"
    Require ("$($contracts.verdict)" -ceq 'PASS') `
        'the CAP-14A contract cross-checks did not PASS'
    Require ("$($contracts.policy_callers)" -ceq 'tools/bundler/pwebbundle.pas') `
        "the policy unit has callers other than the bundler: $($contracts.policy_callers)"
    Require ("$($contracts.policy_unit_in_host)" -cne 'true') `
        'a compiled release host links the policy unit'
} else {
    Row 'csp_contracts' 'unmeasured'
    Row 'csp_policy_callers' 'unmeasured'
    Row 'csp_policy_unit_in_host' 'unmeasured'
    Require $false `
        'build/cap14a/contracts.json is absent -- run check_cap14a_contracts.ps1 first'
}

# --- C1: one leg per refusal class ------------------------------------------
$refusalClasses = [ordered]@{
    'refuse-inline-script'   = 'bundle_inline_script'
    'refuse-external-script' = 'bundle_external_script'
    'refuse-inline-handler'  = 'bundle_inline_handler'
    'refuse-javascript-url'  = 'bundle_javascript_url'
    'refuse-unterminated'    = 'bundle_html_unterminated'
}
$seenClasses = New-Object System.Collections.Generic.List[string]
$ansiSeen = $false
foreach ($name in $refusalClasses.Keys) {
    $cause = $refusalClasses[$name]
    $out = Join-Path $scratch "$name.pwb"
    Remove-Item -Force -ErrorAction SilentlyContinue $out
    $r = Pack (Join-Path $fixtures $name) $out
    Require ($r.Code -ne 0) "$name packed: the CSP refusal did not fire"
    Require ($r.Err.Contains($cause)) `
        "$name did not name its cause '$cause': $($r.Err.Trim())"
    # THE CAUSE NAMES A FILE AND A LINE, which is the difference between a
    # refusal a developer can act on and one they have to bisect
    Require ($r.Err -match [regex]::Escape($cause) + ': index\.html:\d+:') `
        "$name did not name file and line: $($r.Err.Trim())"
    Require (-not (Test-Path -LiteralPath $out)) `
        "$name left an output behind"
    if ($r.Err.Contains("`e") -or $r.Out.Contains("`e")) { $ansiSeen = $true }
    if (-not $seenClasses.Contains($cause)) { $seenClasses.Add($cause) }
}

# --- C3: the two refusals to JUDGE ------------------------------------------
# The UTF-16 fixture is WRITTEN HERE rather than committed, and the reason is
# the same one the headless suite gives: a committed UTF-16 document is a
# file every text tool in the repository would try to normalise, and one
# `.gitattributes` rule away from arriving as UTF-8 and testing nothing.
$bomDist = Join-Path $scratch 'refuse-utf16'
New-Item -ItemType Directory -Force $bomDist | Out-Null
$utf16 = [System.Text.UnicodeEncoding]::new($false, $true)
[System.IO.File]::WriteAllBytes((Join-Path $bomDist 'index.html'),
    ($utf16.GetPreamble() + $utf16.GetBytes('<html><body>x</body></html>')))
$out = Join-Path $scratch 'refuse-utf16.pwb'
Remove-Item -Force -ErrorAction SilentlyContinue $out
$r = Pack $bomDist $out
Require ($r.Code -ne 0) 'a UTF-16 document packed'
Require ($r.Err.Contains('bundle_html_encoding')) `
    "the UTF-16 document did not name bundle_html_encoding: $($r.Err.Trim())"
Require (-not (Test-Path -LiteralPath $out)) 'the UTF-16 refusal left an output'
if (-not $seenClasses.Contains('bundle_html_encoding')) {
    $seenClasses.Add('bundle_html_encoding')
}
Row 'bundle_refusal_classes' (($seenClasses | Sort-Object) -join ',')
Row 'bundle_refusal_count' "$($seenClasses.Count)"
Require ($seenClasses.Count -eq 6) `
    "only $($seenClasses.Count) of the six refusal causes fired"

# --- C2: the accept classes -------------------------------------------------
# One signage-shaped dist carrying every construct that MUST pack: a JSON
# data block, an ld+json block, a text/template block, an inline <style>, a
# style= attribute, a same-origin classic src, a module WITH a src, an HTML
# comment holding a <script>, a CDATA section, a `>` inside an attribute
# value, a <noscript> whose content is raw text, and an SVG asset carrying an
# onload= that is inert by the image context rather than by the CSP.
$signage = Join-Path $fixtures 'signage'
$signageOut = Join-Path $scratch 'signage.pwb'
Remove-Item -Force -ErrorAction SilentlyContinue $signageOut
$r = Pack $signage $signageOut
Require ($r.Code -eq 0) "the accept corpus was refused: $($r.Err.Trim())"
Require (Test-Path -LiteralPath $signageOut) 'the accept corpus produced no archive'
# THE CLASS LIST IS A MEASUREMENT, NOT A CLAIM. A hand-written list beside a
# fixture is one edit away from asserting that a construct was accepted after
# somebody deleted it - the vacuous-pass shape this repository refuses
# everywhere else - so every class names the bytes in the fixture that carry
# it, and a class whose construct is gone fails here rather than passing.
$acceptWitness = [ordered]@{
    'data_block_json'        = 'type="application/json"'
    'data_block_ldjson'      = 'type="application/ld+json"'
    'data_block_template'    = 'type="text/template"'
    'inline_style_element'   = '<style>'
    'style_attribute'        = 'style="justify-content: center"'
    'same_origin_src'        = '<SCRIPT SRC="/assets/app.js">'
    'module_with_src'        = 'type="module" crossorigin src="./assets/boot.js"'
    'comment_holding_script' = '<script>alert(1)</script>'
    'cdata_section'          = '<![CDATA['
    'gt_inside_attribute'    = 'data-caption="width > height"'
    'raw_text_noscript'      = '<noscript>'
    'svg_asset_not_scanned'  = 'onload="init()"'
}
$signageDoc = [System.IO.File]::ReadAllText((Join-Path $signage 'index.html'))
$signageSvg = [System.IO.File]::ReadAllText(
    (Join-Path $signage 'assets/logo.svg'))
$acceptClasses = New-Object System.Collections.Generic.List[string]
foreach ($cls in $acceptWitness.Keys) {
    $needle = $acceptWitness[$cls]
    if ($signageDoc.Contains($needle) -or $signageSvg.Contains($needle)) {
        $acceptClasses.Add($cls)
    } else {
        Require $false `
            "the accept corpus no longer carries '$cls' (looked for: $needle)"
    }
}
Row 'bundle_accept_classes' (($acceptClasses | Sort-Object) -join ',')
Row 'bundle_accept_count' "$($acceptClasses.Count)"
Require ($acceptClasses.Count -eq 12) `
    "the accept corpus witnesses $($acceptClasses.Count) of the twelve ratified classes"
# and the accept path is DETERMINISTIC, which is what says this shard moved
# no archive bytes: the same dist packs to the same bytes twice
$signageTwice = Join-Path $scratch 'signage-2.pwb'
Remove-Item -Force -ErrorAction SilentlyContinue $signageTwice
$r2 = Pack $signage $signageTwice
Require ($r2.Code -eq 0) 'the accept corpus failed its second pack'
$h1 = (Get-FileHash -LiteralPath $signageOut -Algorithm SHA256).Hash.ToLowerInvariant()
$h2 = (Get-FileHash -LiteralPath $signageTwice -Algorithm SHA256).Hash.ToLowerInvariant()
Row 'bundle_accept_sha256' $h1
Row 'bundle_accept_deterministic' (Bool ($h1 -ceq $h2))
Require ($h1 -ceq $h2) "the accept corpus is not deterministic: $h1 vs $h2"

# --- C4: one of each violation, in ONE dist, reported in ONE round ----------
# DERIVED from the accept corpus rather than committed beside it, so the two
# can never drift into disagreeing about what a signage dist looks like.
$hostile = Join-Path $scratch 'signage-hostile'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $hostile
Copy-Item -Recurse -LiteralPath $signage -Destination $hostile
$doc = Join-Path $hostile 'index.html'
$text = [System.IO.File]::ReadAllText($doc).Replace("`r`n", "`n")
$inject = @(
    '<div onmouseenter="hover()">handler</div>',
    '<a href="javascript:next()">javascript url</a>',
    '<script>window.__CONFIG__ = { endpoint: "/api" };</script>',
    '<script src="https://cdn.example.invalid/vendor.min.js"></script>'
) -join "`n"
$text = $text.Replace('</body>', $inject + "`n</body>")
[System.IO.File]::WriteAllText($doc, $text,
    (New-Object System.Text.UTF8Encoding($false)))
$hostileOut = Join-Path $scratch 'signage-hostile.pwb'
Remove-Item -Force -ErrorAction SilentlyContinue $hostileOut
$r = Pack $hostile $hostileOut
Require ($r.Code -ne 0) 'the hostile signage dist packed'
$oneRound = @('bundle_inline_handler', 'bundle_javascript_url',
    'bundle_inline_script', 'bundle_external_script')
$missing = @($oneRound | Where-Object { -not $r.Err.Contains($_) })
Row 'bundle_one_round_causes' (($oneRound | Sort-Object) -join ',')
Row 'bundle_one_round_complete' (Bool ($missing.Count -eq 0))
Require ($missing.Count -eq 0) `
    "one round did not report every class; missing: $($missing -join ', ')"
Require (-not (Test-Path -LiteralPath $hostileOut)) `
    'the hostile dist left an output behind'
if ($r.Err.Contains("`e")) { $ansiSeen = $true }

# --- C6: a refusal never disturbs a previous output -------------------------
$keep = Join-Path $scratch 'keep.pwb'
Copy-Item -LiteralPath $signageOut -Destination $keep -Force
$before = (Get-FileHash -LiteralPath $keep -Algorithm SHA256).Hash
$r = Pack $hostile $keep
Require ($r.Code -ne 0) 'the hostile dist packed over a previous output'
$after = (Get-FileHash -LiteralPath $keep -Algorithm SHA256).Hash
Row 'bundle_refusal_preserves_previous' (Bool ($before -ceq $after))
Require ($before -ceq $after) 'a refusal disturbed the previous output'

# --- C7: no ANSI when redirected --------------------------------------------
Row 'bundle_refusal_ansi_seen' (Bool $ansiSeen)
Require (-not $ansiSeen) 'an ESC byte reached a redirected stream'

# --- C5: every existing corpus still packs ----------------------------------
# The claim this shard has to earn: an additive refusal that broke a shipped
# corpus would be a regression wearing a fix's clothes. The dist list is
# packed for real; the documents that are NOT part of a dist - the two
# templates and the four runtime fixtures - are packed as a one-document
# dist, which runs them through the same binary and the same scan.
$corpusDists = @(
    'examples/04-react/frontend/dist',
    'examples/05-pas2js/frontend/dist',
    'examples/06-assets/frontend/dist',
    'examples/07-quickjs/frontend/dist',
    'build/cap10c1/stage/react/demo/frontend/dist',
    "build/cap10c1/stage/pas2js/demo/dist/$target/dist",
    'build/cap10c2/stage/react/demo/frontend/dist',
    "build/cap10c3/stage/pas2js/demo/dist/$target/dist"
)
$corpusDocs = @(
    'tools/templates/react/frontend/index.html',
    'tools/templates/pas2js/frontend/index.html',
    'tools/templates/fixture/frontend/index.html',
    'test/cap7m/fixture/index.html',
    'test/cap8b/fixture/index.html',
    'test/cap8b/fixture/assets/child.html',
    'test/cap8c/fixture/login.html',
    'test/cap8c/fixture/main.html',
    'test/cap9c2/fixture/index.html'
)
$packed = 0
$refused = New-Object System.Collections.Generic.List[string]
$viteSeen = $false
$pas2jsSeen = $false
foreach ($d in $corpusDists) {
    $full = Join-Path $repoRoot $d
    if (-not (Test-Path -LiteralPath $full)) {
        Write-Host "[cap14a] corpus absent in this workspace: $d"
        continue
    }
    $o = Join-Path $scratch 'corpus.pwb'
    Remove-Item -Force -ErrorAction SilentlyContinue $o
    $r = Pack $full $o
    if ($r.Code -eq 0) {
        $packed++
        if ($d -match 'react') { $viteSeen = $true }
        if ($d -match 'pas2js') { $pas2jsSeen = $true }
    } else {
        $refused.Add("$d :: $($r.Err.Trim())")
    }
}
$one = Join-Path $scratch 'onedoc'
foreach ($f in $corpusDocs) {
    $full = Join-Path $repoRoot $f
    if (-not (Test-Path -LiteralPath $full)) {
        $refused.Add("$f :: absent")
        continue
    }
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $one
    New-Item -ItemType Directory -Force $one | Out-Null
    Copy-Item -LiteralPath $full -Destination (Join-Path $one 'index.html')
    $o = Join-Path $scratch 'onedoc.pwb'
    Remove-Item -Force -ErrorAction SilentlyContinue $o
    $r = Pack $one $o
    if ($r.Code -eq 0) { $packed++ } else { $refused.Add("$f :: $($r.Err.Trim())") }
}
Row 'bundle_corpora_packed' "$packed"
Row 'bundle_corpora_refused' "$($refused.Count)"
Row 'bundle_corpora_pack' (Bool ($refused.Count -eq 0))
Row 'bundle_corpus_vite_output' (Bool $viteSeen)
Row 'bundle_corpus_pas2js_output' (Bool $pas2jsSeen)
foreach ($x in $refused) { Write-Host "CORPUS REFUSED: $x" }
Require ($refused.Count -eq 0) `
    "$($refused.Count) existing corpus item(s) stopped packing"
# A FLOOR, because "zero refused" is also what a leg that packed NOTHING would
# report. The four example dists and the nine committed documents are in every
# checkout; the staged Vite and Pas2JS outputs are the leg's own and are
# counted above them.
Require ($packed -ge ($corpusDocs.Count + 4)) `
    ("only $packed corpus item(s) were packed; $($corpusDocs.Count + 4) are " +
     'committed in every checkout, so this leg measured less than nothing')

# --- C8: no override --------------------------------------------------------
# The option surface, read out of the bundler's own parser. A flag that
# packed an inline script anyway would be a lie told at build time and paid
# for at run time, so the absence is measured rather than promised.
$src = [System.IO.File]::ReadAllText(
    (Join-Path $repoRoot 'tools/bundler/pwebbundle.pas'))
$opts = @([regex]::Matches($src, "'(--[a-z0-9-]+)") |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$ratified = @('--include-sourcemaps', '--max-asset-bytes', '--min-runtime',
    '--verify')
Row 'bundle_option_surface' ($opts -join ',')
Row 'bundle_override_options' "$(@($opts | Where-Object { $ratified -notcontains $_ }).Count)"
Require ((($opts | Sort-Object) -join ',') -ceq (($ratified | Sort-Object) -join ',')) `
    "the bundler's option surface moved: $($opts -join ', ')"

# --- C9: the digests four targets must agree on -----------------------------
Row 'bundler_digest' (Sha256Lf (Join-Path $repoRoot 'tools/bundler/pwebbundle.pas'))
Row 'csp_policy_digest' `
    (Sha256Lf (Join-Path $repoRoot 'src/assets/pweb.assets.htmlpolicy.pas'))
$policyCorpus = Join-Path $repoRoot 'build/cap7f/html-policy.txt'
if (Test-Path -LiteralPath $policyCorpus) {
    $t = [System.IO.File]::ReadAllText($policyCorpus).Replace("`r`n", "`n")
    $decisions = @($t -split "`n" | Where-Object { $_.StartsWith('decision ') })
    Row 'html_policy_digest' (Sha256Text $t)
    Row 'html_policy_corpus_lines' "$($decisions.Count)"
    Require ($t.Contains('verdict=PASS')) `
        'the headless html-policy corpus does not record a PASS'
    Require ($decisions.Count -ge 40) `
        "the html-policy corpus carries only $($decisions.Count) decision(s)"
} else {
    Row 'html_policy_digest' 'unmeasured'
    Row 'html_policy_corpus_lines' '0'
    Require $false `
        'build/cap7f/html-policy.txt is absent -- the pwebtests suite has not run'
}

# --- B1 / D1: the two pipeline seams, on a REAL generated project -----------
# A PAS2JS project, and that is a measurement rather than a preference: its
# pipeline reaches `pack` with no npm, no registry and no network at all, so
# the two seams below are proven without borrowing another shard's install.
# React's own path is covered by C5 above, which packs Vite's REAL output.
$pinnedPas2js = @('deps/pas2js/bin', 'deps/pas2js-linux/bin',
    'deps/pas2js-darwin/bin') |
    ForEach-Object { Join-Path $repoRoot $_ } |
    Where-Object { Test-Path -LiteralPath $_ }
if ($pinnedPas2js.Count -gt 0) {
    $env:PATH = (($pinnedPas2js -join [System.IO.Path]::PathSeparator) +
        [System.IO.Path]::PathSeparator + $env:PATH)
}
$pas2jsOnPath = $null -ne (Get-Command pas2js -ErrorAction SilentlyContinue)
Row 'cap14a_pas2js_on_path' (Bool $pas2jsOnPath)
Require $pas2jsOnPath `
    'pas2js is not on PATH and no pinned copy exists under deps/ -- the build and dev seams cannot be measured'

$stage = Join-Path $work 'stage'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $stage
New-Item -ItemType Directory -Force $stage | Out-Null
$cwd = Join-Path $work 'cwd'
New-Item -ItemType Directory -Force $cwd | Out-Null
function RunCli([string[]]$CliArgs, [string]$WorkDir) {
    $so = Join-Path $scratch 'cli-stdout.txt'
    $se = Join-Path $scratch 'cli-stderr.txt'
    Remove-Item -Force -ErrorAction SilentlyContinue $so, $se
    $p = Start-PWebProcess -FilePath $pweb -ArgumentList $CliArgs -Wait -PassThru `
        -NoNewWindow -WorkingDirectory $WorkDir `
        -RedirectStandardOutput $so -RedirectStandardError $se
    return [pscustomobject]@{
        Code = $p.ExitCode
        Out  = if (Test-Path -LiteralPath $so) { [System.IO.File]::ReadAllText($so) } else { '' }
        Err  = if (Test-Path -LiteralPath $se) { [System.IO.File]::ReadAllText($se) } else { '' }
    }
}
$r = RunCli @('create', 'demo', '--ui', 'pas2js', '--bundle-id', 'com.example.demo') $stage
Require ($r.Code -eq 0) "scaffolding the pas2js project failed: $($r.Code) $($r.Err.Trim())"
$proj = Join-Path $stage 'demo'
$markup = Join-Path $proj 'frontend/index.html'
$clean = [System.IO.File]::ReadAllText($markup)
function WriteMarkup([string]$Text) {
    [System.IO.File]::WriteAllText($markup, $Text,
        (New-Object System.Text.UTF8Encoding($false)))
}
$INLINE = '<script>window.__SIGNAGE__ = { rotate: 30 };</script>'

# B1a: the project builds clean first, so the release the refusal must leave
# alone is one this gate watched being made
$r = RunCli @('build', '--project', $proj) $cwd
Require ($r.Code -eq 0) "the clean pas2js build failed: $($r.Code) $($r.Err.Trim())"
$release = Join-Path $proj "dist/$target/release"
Require (Test-Path -LiteralPath $release) 'the clean build committed no release'
function ReleaseFingerprint {
    if (-not (Test-Path -LiteralPath $release)) { return '<absent>' }
    $lines = @(Get-ChildItem -LiteralPath $release -Recurse -File -Force |
        Sort-Object FullName |
        ForEach-Object {
            $rel = $_.FullName.Substring($release.Length).TrimStart('\', '/')
            "$($rel -replace '\\', '/')|$($_.Length)|" +
                (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        })
    return Sha256Text ($lines -join "`n")
}
$releaseBefore = ReleaseFingerprint
Row 'build_clean_exit' "$($r.Code)"

# B1b: the same project, one inline <script> later
WriteMarkup ($clean.Replace('</body>', "$INLINE`n</body>"))
$r = RunCli @('build', '--project', $proj) $cwd
$combined = $r.Out + "`n" + $r.Err
Row 'build_refusal_exit' "$($r.Code)"
Row 'build_refusal_cause_forwarded' (Bool ($combined.Contains('bundle_inline_script')))
Row 'build_refusal_stage' $(if ($combined -match '(?m)^pweb: pack: FAILED (\S+)') { $Matches[1] } else { 'unmeasured' })
$releaseAfter = ReleaseFingerprint
Row 'build_refusal_release_unchanged' (Bool ($releaseBefore -ceq $releaseAfter))
Require ($r.Code -eq 5) `
    ('pweb build answered ' + $r.Code + ' for a CSP-refused dist, expected 5')
Require ($combined.Contains('bundle_inline_script')) `
    "the bundler's typed cause did not reach the build output"
Require ($combined -match '(?m)^pweb: pack: FAILED stage_exited') `
    'the pack stage did not record its ratified typed failure'
Require ($releaseBefore -ceq $releaseAfter) `
    'a refused build disturbed the previous release'
# and NOTHING new was committed: the layout stage never runs after a failed
# pack, which is the CAP-10C1 property this shard inherits rather than adds
$leftovers = @(Get-ChildItem -LiteralPath (Join-Path $proj "dist/$target") `
    -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'release.*' -or $_.Name -like '.release*' })
Row 'build_refusal_partial_layout' (Bool ($leftovers.Count -ne 0))
Require ($leftovers.Count -eq 0) `
    "a refused build left $($leftovers.Count) partial layout director(y|ies)"

# D1: the development loop. The generation is refused, the PREVIOUS
# generation stays live, the host is NOT restarted, and the loop recovers.
WriteMarkup $clean
$devDir = Join-Path $proj "dist/$target/dev"
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $devDir
$do = Join-Path $work 'dev-stdout.txt'
$de = Join-Path $work 'dev-stderr.txt'
Remove-Item -Force -ErrorAction SilentlyContinue $do, $de
$dev = Start-PWebProcess -FilePath $pweb `
    -ArgumentList @('dev', '--project', $proj) -PassThru -NoNewWindow `
    -WorkingDirectory $cwd -RedirectStandardOutput $do -RedirectStandardError $de
$seen = ''
$deadline = (Get-Date).AddSeconds(600)
while (((Get-Date) -lt $deadline) -and (-not $dev.HasExited)) {
    $seen = (ReadLive $de) + (ReadLive $do)
    if ($seen -match '(?m)^pweb: generation 1 ready') { break }
    Start-Sleep -Milliseconds 500
}
Row 'dev_gen1_ready' (Bool ($seen -match '(?m)^pweb: generation 1 ready'))
Require ($seen -match '(?m)^pweb: generation 1 ready') `
    'the development loop never published generation 1'
$hostPidBefore = if ($seen -match '(?m)^pweb: started pid (\d+)') { $Matches[1] } else { '' }
Row 'dev_host_pid_seen' (Bool ($hostPidBefore -ne ''))

# the edit that the CSP will not run
WriteMarkup ($clean.Replace('</body>', "$INLINE`n</body>"))
$deadline = (Get-Date).AddSeconds(600)
$refusedSeen = $false
while (((Get-Date) -lt $deadline) -and (-not $dev.HasExited)) {
    $seen = (ReadLive $de) + (ReadLive $do)
    if ($seen.Contains('bundle_inline_script')) { $refusedSeen = $true; break }
    Start-Sleep -Milliseconds 500
}
Row 'dev_refusal_cause_forwarded' (Bool $refusedSeen)
Require $refusedSeen `
    "the bundler's typed cause never reached the development output"
Require (-not $dev.HasExited) `
    'a refused generation stopped the development loop'
$hostPidAfter = if ($seen -match '(?m)^pweb: started pid (\d+)') { $Matches[1] } else { '' }
Row 'dev_host_pid_unchanged' `
    (Bool (($hostPidBefore -ne '') -and ($hostPidBefore -ceq $hostPidAfter)))
Require ($hostPidBefore -ceq $hostPidAfter) `
    "the host was restarted by a refused generation: $hostPidBefore -> $hostPidAfter"
$gen1 = Join-Path $devDir 'gen-1/app.pwb'
$gen2 = Join-Path $devDir 'gen-2'
Row 'dev_previous_generation_live' (Bool (Test-Path -LiteralPath $gen1))
Row 'dev_refused_generation_published' (Bool (Test-Path -LiteralPath $gen2))
Require (Test-Path -LiteralPath $gen1) `
    'the previous generation did not survive the refusal'
Require (-not (Test-Path -LiteralPath $gen2)) `
    'a generation the CSP cannot run was published'

# and the loop recovers the moment the document is fixed
WriteMarkup $clean
$deadline = (Get-Date).AddSeconds(600)
$recovered = $false
while (((Get-Date) -lt $deadline) -and (-not $dev.HasExited)) {
    $seen = (ReadLive $de) + (ReadLive $do)
    if ($seen -match '(?m)^pweb: generation 2 ready') { $recovered = $true; break }
    Start-Sleep -Milliseconds 500
}
Row 'dev_recovered_after_fix' (Bool $recovered)
Require $recovered 'the development loop did not recover when the document was fixed'
if (-not $dev.HasExited) { $dev.Kill($true) }
$dev.WaitForExit(30000) | Out-Null
Row 'dev_refusal_ansi_seen' (Bool ($seen.Contains("`e")))

# --- the record -------------------------------------------------------------
Row 'cap14a_gates' $(if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' })
$json = ($rows | ConvertTo-Json -Depth 3)
$recordFile = Join-Path $work "cli-$target.json"
[System.IO.File]::WriteAllText($recordFile, ($json -replace "`r`n", "`n") + "`n",
    (New-Object System.Text.UTF8Encoding($false)))
Write-Host ''
foreach ($k in $rows.Keys) { Write-Host ("  {0,-38} {1}" -f $k, $rows[$k]) }
Write-Host ''
Write-Host "[cap14a] record written to $recordFile"
if ($failures.Count -gt 0) {
    Write-Host "CAP-14A GATES FAILED ($($failures.Count))"
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}
Write-Host 'CAP14A_GATES_PASS the bundler refuses what the CSP will not run'
exit 0
