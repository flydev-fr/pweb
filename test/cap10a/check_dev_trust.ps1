# CAP-10A: the development-trust decision, pinned mechanically before any
# development code exists.
#
# THE RATIFIED MODEL (SPEC.md "Decided, implementation deferred";
# security-model.md "Navigation policy"):
#
#   the privileged application origin is pweb://app in DEVELOPMENT and in
#   PRODUCTION alike. `pweb dev` will serve the frontend BEHIND that handler
#   rather than re-pointing the privileged origin at 127.0.0.1. React HMR may
#   use ONE narrowly scoped development-only CSP data-channel allowance,
#   ws://127.0.0.1:<native-selected-port>, which is a TRANSPORT exception and
#   never an ORIGIN exception. A production build carries no localhost and no
#   WebSocket allowance of any kind. Pas2JS development needs no WebSocket.
#
# WHY A GATE NOW, WITH NO DEV MODE TO GATE. Because the rule dies the other
# way round: a dev mode is written, an allowance is added "temporarily" to the
# shared profile, and by the time anyone looks the production CSP has a
# localhost entry nobody can date. This script fails the moment the
# PRODUCTION half stops being true, which is the half that matters and the
# only half that exists yet.
#
# Checkout-only: no build, no toolchain, no network. Runs in every platform
# job and on any dev host.
#
# Usage: pwsh test/cap10a/check_dev_trust.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
$report = New-Object System.Collections.Generic.List[string]

# --- 1. the production CSP -------------------------------------------------
# The native policy is attached to EVERY served response and cannot be
# weakened by the bundle (multiple policies combine restrictively), so it is
# the one place a development allowance would have to appear.
$policy = 'src/security/pweb.navigation.policy.pas'
if (-not (Test-Path $policy)) { throw "missing $policy" }
$policyText = [System.IO.File]::ReadAllText($policy)
$cspMatch = [regex]::Match($policyText,
    "PWEB_NATIVE_CSP\s*:\s*RawUtf8\s*=\s*((?:\s*'[^']*'\s*\+?)+)\s*;")
if (-not $cspMatch.Success) {
    throw 'PWEB_NATIVE_CSP could not be read from the navigation policy'
}
# Pascal escapes a quote by doubling it, and the CSP is full of them
# (`default-src ''self''`), so the concatenated literal is un-doubled back
# into the bytes the engine actually receives
$csp = (-join ([regex]::Matches($cspMatch.Groups[1].Value, "'((?:[^']|'')*)'") |
    ForEach-Object { $_.Groups[1].Value })).Replace("''", "'")
$report.Add("production CSP: $csp")

foreach ($banned in 'ws:', 'wss:', 'localhost', '127.0.0.1', 'http:') {
    if ($csp.Contains($banned)) {
        $violations.Add("the production CSP contains '$banned': $csp")
    }
}
foreach ($required in "default-src 'self'", "connect-src 'self'",
                      "script-src 'self'", "frame-ancestors 'none'") {
    if (-not $csp.Contains($required)) {
        $violations.Add("the production CSP no longer carries `"$required`"")
    }
}

# --- 2. the privileged origin ---------------------------------------------
# pweb://app is the only trusted origin, and it is decided by PARSED
# components in PWebNavTrustedUri. What this gate adds is that no production
# source has grown a SECOND origin that looks privileged.
$devOrigins = 'http://127\.0\.0\.1|http://localhost|ws://127\.0\.0\.1|' +
    'ws://localhost|wss://'
$surface = @(
    (Get-ChildItem src -Recurse -File -Include '*.pas', '*.inc', '*.h', '*.mm'),
    (Get-ChildItem examples -Recurse -File -Include '*.pas' |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|dist)[\\/]' }),
    (Get-ChildItem tools -Recurse -File -Include '*.pas'),
    (Get-ChildItem sdk -Recurse -File -Include '*.ts', '*.pas' |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|dist)[\\/]' })
) | ForEach-Object { $_ }
# only a STRING LITERAL counts. A comment that names a development origin is
# how this repository explains what it refuses - pweb.navigation.policy's own
# header records that every wss:// was blocked on all four targets - and a
# gate that could not tell a literal from its explanation would forbid the
# explanation. What must not exist is the origin as DATA.
$literalForms = @("'((?:[^']|'')*)'", '"([^"]*)"', '`([^`]*)`')
foreach ($file in $surface) {
    $rel = ($file.FullName.Substring($repoRoot.Length).TrimStart('\', '/')) `
        -replace '\\', '/'
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
        $lineNo++
        foreach ($form in $literalForms) {
            foreach ($m in [regex]::Matches($line, $form)) {
                if ($m.Groups[1].Value -match $devOrigins) {
                    $violations.Add(("a development origin appears as DATA on " +
                        "the production surface: ${rel}:${lineNo}: " +
                        $m.Groups[1].Value))
                }
            }
        }
    }
}

# --- 3. the canonical wording -----------------------------------------------
# security-model.md must describe the SHIPPED CAP-8B result: a privileged
# WebView never navigates to external content, and an approved https/mailto
# URI reaches the operating system only through a capability-authorized
# runtime invocation. The pre-CAP-8B wording said the links "open in the
# system browser", which describes a navigation-time behaviour CAP-8B
# measured to be undecidable and removed.
$model = '_bmad-output/specs/spec-pweb/security-model.md'
if (-not (Test-Path $model)) { throw "missing $model" }
$modelText = [System.IO.File]::ReadAllText($model)
foreach ($phrase in
    'never navigates to external content',
    'capability-authorized',
    'pweb.openExternal') {
    if (-not $modelText.Contains($phrase)) {
        $violations.Add(("security-model.md does not carry the ratified " +
            "CAP-8B wording: `"$phrase`" is absent"))
    }
}
# and it must NOT still promise the gesture-based opener
if ($modelText -match '(?m)^\s*`https:`\s+and\s+`mailto:`\s+links\s+open\s+in\s+the\s+system\s+browser') {
    $violations.Add('security-model.md still describes the removed ' +
        'gesture-based opener behaviour')
}

# --- 4. the dev contract is WRITTEN DOWN ------------------------------------
# A decision that exists only in a reviewer's memory is not ratified. The
# public contract document must state the invariant, the single exception and
# its production exclusion, so CAP-10C implements what was agreed rather than
# what it can remember.
$contract = 'docs/cli-contract.md'
if (-not (Test-Path $contract)) { throw "missing $contract" }
$contractText = [System.IO.File]::ReadAllText($contract)
foreach ($phrase in 'pweb://app', 'ws://127.0.0.1', 'never an origin exception',
                    'no production build') {
    if (-not $contractText.Contains($phrase)) {
        $violations.Add(("docs/cli-contract.md does not record the dev-trust " +
            "decision: `"$phrase`" is absent"))
    }
}

# --- 5. CAP-10C2: the DEVELOPMENT half, now that it exists ------------------
# Sections 1-4 pinned the production half before any development code
# existed, which was the whole point: the rule dies when a dev mode is
# written and an allowance is added "temporarily" to a shared profile. The
# dev mode is written now, so this section pins what CAP-10C2 decided.
#
# The source sweep in section 2 already covers src/** and tools/**, so a
# ws:// or a 127.0.0.1 literal appearing in the dev loop or the dev host is
# ALREADY a violation above. What is added here is the positive half: the
# development composition exists, it navigates to nothing but the one
# privileged origin, it selects its mode natively, and the ratified-but-
# unused WebSocket allowance is still ratified, still unused, and still
# absent from every profile.
$devHost = 'src/webview/pweb.webview.devhost.pas'
$devLoop = 'tools/pweb/pweb.cli.dev.pas'
$devLayout = 'tools/pweb/pweb.cli.devlayout.pas'
$devContract = 'docs/dev-contract.md'
foreach ($f in $devHost, $devLoop, $devLayout, $devContract) {
    if (-not (Test-Path $f)) {
        $violations.Add("CAP-10C2 development surface is missing: $f")
    }
}
if (Test-Path $devHost) {
    $devHostText = [System.IO.File]::ReadAllText($devHost)
    # THE ONE NAVIGATION. The dev host must not call webview_navigate at
    # all: re-navigation goes through PWebHostRequestReload, which carries
    # PWEB_HOST_ORIGIN and no parameter, so a development build has no way
    # to name a second destination even by accident.
    if ($devHostText -match 'webview_navigate') {
        $violations.Add(('the development host calls webview_navigate ' +
            'directly: the ratified switch is PWebHostRequestReload, whose ' +
            'only destination is PWEB_HOST_ORIGIN'))
    }
    if (-not $devHostText.Contains('PWebHostRequestReload')) {
        $violations.Add('the development host does not use PWebHostRequestReload')
    }
    # it must SERVE a packed bundle and never a folder: a dev store that
    # could read loose files is a dev store with a different path grammar
    if (-not $devHostText.Contains('PWebBundleLoadFile')) {
        $violations.Add(('the development host does not open its generations ' +
            'through the frozen PWebBundleLoadFile'))
    }
    foreach ($banned in 'pweb.assets.folder', 'TFolderAssetStore') {
        if ($devHostText.Contains($banned)) {
            $violations.Add("the development host reaches a FOLDER store: $banned")
        }
    }
}
# THE MODE IS NATIVE-CONTROLLED. PWEB_DEV reaches a compiler from the CLI's
# own argument builder and from nowhere else - not from pweb.json, not from
# a frontend file, not from an environment variable.
$native = 'tools/pweb/pweb.cli.native.pas'
if (Test-Path $native) {
    $nativeText = [System.IO.File]::ReadAllText($native)
    if (-not ($nativeText -match "'-d'\s*\+\s*PWEB_CLI_DEV_DEFINE")) {
        $violations.Add(('pweb.cli.native does not build the development ' +
            'define from PWEB_CLI_DEV_DEFINE: the mode must be spelled once ' +
            'and reach the compiler from this one place'))
    }
}
$toolchain = 'tools/pweb/pweb.cli.toolchain.pas'
if (Test-Path $toolchain) {
    $toolchainText = [System.IO.File]::ReadAllText($toolchain)
    if ($toolchainText -notmatch "(?m)^\s*PWEB_CLI_DEV_DEFINE\s*=\s*'PWEB_DEV'\s*;") {
        $violations.Add("$toolchain does not define PWEB_CLI_DEV_DEFINE = 'PWEB_DEV'")
    }
}
# and no environment variable may select it, anywhere on the surface
$modeEnvRx = 'PWEB_DEV_ROOT|PWEB_MODE|PWEB_DEVELOPMENT'
foreach ($file in $surface) {
    $rel = ($file.FullName.Substring($repoRoot.Length).TrimStart('\', '/')) `
        -replace '\\', '/'
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
        $lineNo++
        if ($line -match 'GetEnvironmentVariable|getenv') {
            if ($line -match $modeEnvRx) {
                $violations.Add(("the development mode is read from the " +
                    "ENVIRONMENT at ${rel}:${lineNo} -- the mode is " +
                    'native-controlled and arrives on a compiler command line'))
            }
        }
    }
}
# THE PRODUCTION TEMPLATE STILL SELECTS THE PRODUCTION HOST. The generated
# program.lpr may name the development composition only inside its
# PWEB_DEV region, which is what makes a release build unable to link it.
$tpl = 'tools/templates/react/src/program.lpr'
if (Test-Path $tpl) {
    $inDev = $false
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($tpl)) {
        $lineNo++
        if ($line -match '\{\$ifdef\s+PWEB_DEV\}') { $inDev = $true; continue }
        if ($line -match '\{\$else\}') { $inDev = $false; continue }
        if ($line -match '\{\$endif\s+PWEB_DEV\}') { $inDev = $false; continue }
        if ((-not $inDev) -and
            ($line -match 'devhost|PWebDevHostRun')) {
            $violations.Add(("the generated program names the development " +
                "composition OUTSIDE its PWEB_DEV region: ${tpl}:${lineNo}"))
        }
    }
}
# THE RATIFIED-BUT-UNUSED ALLOWANCE. CAP-10C2 chose rebuild-and-reload, so
# ws://127.0.0.1:<port> is still ratified in the contract, still unused, and
# still absent from every profile. Its presence in the DOCUMENT is required
# (section 4); its absence from every SOURCE profile is section 2. This pins
# the third thing: the contract must record that the shipped dev loop does
# not use it, so a reader cannot mistake a ratification for an implementation.
foreach ($phrase in 'rebuild-and-reload', 'ratified, unused') {
    if (-not $contractText.Contains($phrase)) {
        $violations.Add(("docs/cli-contract.md does not record the CAP-10C2 " +
            "decision: `"$phrase`" is absent"))
    }
}
$report.Add('CAP-10C2: rebuild-and-reload; the ws:// allowance stays ratified, unused and absent')

# --- verdict ----------------------------------------------------------------
New-Item -ItemType Directory -Force build/cap10a | Out-Null
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# CAP-10A development-trust gate')
foreach ($r in $report) { $lines.Add("# $r") }
if ($violations.Count -eq 0) {
    $lines.Add('VERDICT: PASS (production trust profile carries no dev allowance)')
} else {
    $lines.Add("VERDICT: FAIL ($($violations.Count) violation(s))")
    foreach ($v in $violations) { $lines.Add("VIOLATION: $v") }
}
[System.IO.File]::WriteAllText(
    (Join-Path $repoRoot 'build/cap10a/dev-trust.txt'),
    (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))

if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Write-Host "VIOLATION: $v" }
    throw "CAP-10A dev-trust gate FAILED: $($violations.Count) violation(s)"
}
Write-Host ('[CAP-10A] dev trust PASS - pweb://app is the only privileged ' +
    'origin and the production profile carries no HMR allowance')
