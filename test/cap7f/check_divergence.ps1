# CAP-7F: platform-divergence sweep over the PRODUCTION surface (src/**,
# examples/07-quickjs/, examples/08-release/, tools/bundler/, tools/quickjs/,
# tools/pweb/)
# against an explicit, ratified allowlist. Checkout-only: no build, no
# toolchain - it runs in the cap7-aggregate job and on any dev host.
#
# WHAT COUNTS AS A DIVERGENCE: a compiler conditional whose condition names
# a platform symbol ({$ifdef DARWIN}, {$IF Defined(WIN64)}, {$ifndef LINUX},
# {$endif OSWINDOWS} tags included), and - in the SDKs - runtime platform
# sniffing (process.platform and friends). Profile conditionals
# (PWEB_FIXED_RUNTIME) are deliberately NOT platform divergence.
#
# THE ALLOWLIST IS EXACT, per file, by directive COUNT AND FINGERPRINT:
#   - a platform conditional in any file NOT on the allowlist fails,
#     naming file:line - this is what keeps the frozen zero-conditional
#     core units (scheduler, rpc intf/mormot/support, capabilities +
#     capabilities.policy, webview binding/intf, assets
#     intf/support/zip, both SDKs) frozen;
#   - a count CHANGE in an allowlisted file fails too, in EITHER direction:
#     growth is a new divergence, shrinkage means the ratified ground truth
#     moved and the allowlist must be re-ratified in the same commit;
#   - the FINGERPRINT (CAP-8A, closing the CAP-7F ledger entry) is the
#     sha256 of the ordered matched directive TEXTS joined by LF: it
#     catches a SWAP that keeps the count ({$ifdef DARWIN} becoming
#     {$ifdef ANDROID}), which a count alone waves through. Texts, not
#     line numbers, so pure line drift stays quiet by design.
#
# src/platform/{windows,linux,macos}/ is platform-PRIVATE by layout: each
# unit there is a single platform's body, so per-platform conditionals are
# its nature, not divergence - the tree is skipped wholesale.
#
# Emits build/cap7f/divergence.txt (every match, file:line:text, then the
# verdict) and exits nonzero on any violation.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot
New-Item -ItemType Directory -Force build/cap7f | Out-Null
$report = New-Object System.Collections.Generic.List[string]
$violations = New-Object System.Collections.Generic.List[string]

# One directive occurrence = one count. The platform-symbol filter is what
# separates {$ifdef DARWIN} from {$ifdef FPC} or {$ifdef PWEB_FIXED_RUNTIME}.
# BOTH FPC directive spellings are scanned: the brace form {$ifdef X} and
# the parenthesis-star comment form (*$ifdef X*), which is a legal directive
# a brace-only scanner would silently wave through.
$directiveRx = [regex]::new('\{\$\s*(?:ifdef|ifndef|elseif|if|else|endif)\b[^}]*\}',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$directiveParenRx = [regex]::new('\(\*\$\s*(?:ifdef|ifndef|elseif|if|else|endif)\b[^*]*\*\)',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$platformRx = [regex]::new(
    '\b(WIN32|WIN64|WINDOWS|OSWINDOWS|MSWINDOWS|LINUX|DARWIN|UNIX|POSIX|BSD|FREEBSD|NETBSD|OPENBSD|IOS|OSX|MACOS|HAIKU|ANDROID|SOLARIS|SUNOS|AIX|CPUX86_64|CPUX64|CPUX86|CPUAARCH64|CPUARM64|CPUARM|AARCH64|CPU32|CPU64)\b',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

function Get-PlatformDirectiveMatches([string]$Line) {
    $hits = @()
    foreach ($rx in @($directiveRx, $directiveParenRx)) {
        foreach ($m in $rx.Matches($Line)) {
            if ($platformRx.IsMatch($m.Value)) { $hits += $m.Value }
        }
    }
    return $hits
}

# file (repo-relative, forward slashes) -> exact ratified directive count
# plus the sha256 fingerprint of the ordered matched directive texts
# (joined by LF, UTF-8) - both must hold, or the allowlist is re-ratified
# in the same commit
$allow = @{
    'examples/08-release/releaseapp.pas' = @{ directives = 38;  # +6: the CAP-8B guard construction/teardown platform regions
        fingerprint = '8ee3c9085f4af8c3129fd822915f1b6578da94f6d96f6a2f3e9ea5d37fdd572a' }
    # CAP-9C2: the plugin-enabled acceptance host. Fewer regions than the
    # CAP-6 release host because it carries no fixed-runtime profile: the
    # platform alias block, the three pre-create checks, the Cocoa
    # two-phase handler/guard seam, the .app-relative resolution of
    # app.pwb and plugins.zip, and the Windows-only atomic-replace window.
    'examples/07-quickjs/quickjsapp.pas' = @{ directives = 34;
        fingerprint = '4be277b371a7f178e182ca9743a73d25202083775f017b12997da06b5e538c00' }
    'src/lib/pweb.lib.webview.pas'       = @{ directives = 4;   # LIB_WEBVIEW selection block
        fingerprint = 'cec476fd99b6cc8603a8fe330d52982a4c660ae3ffb0af4ec5658e356bce4496' }
    'src/assets/pweb.assets.folder.pas'  = @{ directives = 10;  # Darwin F_GETPATH / Windows wide-API split
        fingerprint = '145ed55144e2e7c509bfda6cc19fadc863a58f41f31747f8835c26ec2e5c48c9' }
    'src/assets/pweb.assets.bundle.pas'  = @{ directives = 6;   # I/O mechanism only (ratified)
        fingerprint = '7fc1e97c840d75a47f92771c8880861bc45a757806738932d4e80f39611a68b9' }
    'tools/bundler/pwebbundle.pas'       = @{ directives = 6;   # Windows wide-API walk (ledgered)
        fingerprint = '7e329077ac3048bfe7a25495f63fb060ebc782fce0115613120ca7ae51718842' }
    'src/script/pweb.script.quickjs.pas' = @{ directives = 4;   # CAP-9A darwin {$L quickjs.o} link + aarch64-darwin pas_* export block (the pin ships no darwin QuickJS support)
        fingerprint = 'dc0f70734b16d12e29ef25343797ab4318cd78d7fa0f7ed2c38a7438bba3f75b' }
    'src/script/pweb.script.release.pas' = @{ directives = 10;  # CAP-9C1: the ONE handle strategy (reparse/O_NOFOLLOW refusal, split as two whole bodies), the absolute-path predicate and the CAP-6 atomic-replace mechanism
        fingerprint = '218a2592aef612d4d6f7fa21de022d015f84a1b1462d7e487520ad9ae5475c19' }
    'tools/quickjs/pwebqjspack.pas'      = @{ directives = 6;   # CAP-9C1: the Windows wide-API source walk (the pwebbundle precedent - the RTL Ansi filesystem layer mistranslates concatenated paths)
        fingerprint = '7e329077ac3048bfe7a25495f63fb060ebc782fce0115613120ca7ae51718842' }
    # CAP-10A: the CLI's platform seam, and the ONLY CLI file with any
    # divergence at all. It carries the whole Windows/POSIX split - raw argv,
    # console mode, canonical paths, exact-case entries, executable
    # resolution and the host engine probe - so that pweb.cli.args,
    # .project, .paths, .probe, .doctor, .report and .toolchain stay at
    # ZERO and this sweep keeps them there.
    'tools/pweb/pweb.cli.platform.pas'   = @{ directives = 24;
        fingerprint = '91f95444ba9fff35c95bb243080042f9e13054797072cfb69ee302bff57fb35b' }
    # CAP-10A: the program, whose only conditional is {$apptype console}
    'tools/pweb/pweb.pas'                = @{ directives = 2;
        fingerprint = '0dc7a84a71485678f01dc0e7032093d6858fb389878b52157a2f69671187305d' }
}

function Get-DirectiveFingerprint([string[]]$Texts) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha.ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes(($Texts -join "`n"))) |
            ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}

# the frozen zero-conditional core, named so a hit there says what it broke
$frozenCore = @(
    'src/rpc/pweb.rpc.scheduler.pas', 'src/rpc/pweb.rpc.intf.pas',
    'src/rpc/pweb.rpc.mormot.pas', 'src/rpc/pweb.rpc.support.pas',
    'src/rpc/pweb.rpc.command.pas',
    'src/security/pweb.capabilities.pas',
    'src/security/pweb.capabilities.policy.pas',
    'src/webview/pweb.webview.binding.pas', 'src/webview/pweb.webview.intf.pas',
    'src/assets/pweb.assets.intf.pas', 'src/assets/pweb.assets.support.pas',
    'src/assets/pweb.assets.zip.pas'
)

function Get-RelPath([string]$FullName) {
    $rel = $FullName.Substring($repoRoot.Length).TrimStart('\', '/')
    return $rel -replace '\\', '/'
}

# --- Pascal surface ---------------------------------------------------------
# tools/quickjs joins the swept surface for the same reason tools/bundler
# did: a build tool that decides what ships is production surface, and a
# platform conditional appearing there unremarked is exactly the drift
# this sweep exists to catch.
# CAP-10A: tools/pweb joins the swept surface for the reason tools/bundler and
# tools/quickjs did - the public lifecycle entry point decides what a developer
# builds, so a platform conditional appearing there unremarked is exactly the
# drift this sweep exists to catch. The CLI concentrates every one of its
# conditionals in pweb.cli.platform by design; the allowlist below is what
# holds that design in place.
$pascalRoots = @('src', 'examples/07-quickjs', 'examples/08-release',
    'tools/bundler', 'tools/quickjs', 'tools/pweb')
$pascalFiles = foreach ($root in $pascalRoots) {
    if (Test-Path $root) {
        Get-ChildItem $root -Recurse -File -Include '*.pas', '*.pp', '*.inc' |
            Where-Object { (Get-RelPath $_.FullName) -notmatch '^src/platform/' }
    }
}

$found = @{}
$foundTexts = @{}
foreach ($file in $pascalFiles) {
    $rel = Get-RelPath $file.FullName
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
        $lineNo++
        foreach ($hit in (Get-PlatformDirectiveMatches $line)) {
            if (-not $found.ContainsKey($rel)) {
                $found[$rel] = @()
                $foundTexts[$rel] = @()
            }
            $found[$rel] += "${rel}:${lineNo}: $hit"
            $foundTexts[$rel] += $hit
        }
    }
}

foreach ($rel in ($found.Keys | Sort-Object)) {
    $hits = $found[$rel]
    foreach ($h in $hits) { $report.Add($h) }
    if (-not $allow.ContainsKey($rel)) {
        $tag = if ($frozenCore -contains $rel) { 'FROZEN ZERO-CONDITIONAL CORE UNIT' }
               else { 'NOT ON THE ALLOWLIST' }
        foreach ($h in $hits) {
            $violations.Add("$tag : $h")
        }
    }
    elseif ($hits.Count -ne $allow[$rel].directives) {
        $violations.Add(("ALLOWLIST COUNT CHANGED for ${rel}: found $($hits.Count), " +
            "ratified $($allow[$rel].directives) -- re-ratify the allowlist in the same commit, lines:"))
        foreach ($h in $hits) { $violations.Add("  $h") }
    }
    else {
        # count intact: a SWAP inside the file still changes the ordered
        # directive texts, and therefore this fingerprint
        $fp = Get-DirectiveFingerprint $foundTexts[$rel]
        if ($fp -cne $allow[$rel].fingerprint) {
            $violations.Add(("ALLOWLIST FINGERPRINT CHANGED for ${rel}: computed $fp, " +
                "ratified $($allow[$rel].fingerprint) -- a directive was substituted or " +
                'reordered; re-ratify the allowlist in the same commit, lines:'))
            foreach ($h in $hits) { $violations.Add("  $h") }
        }
    }
}
# an allowlisted file with ZERO findings is a count change too
foreach ($rel in ($allow.Keys | Sort-Object)) {
    if (-not (Test-Path $rel)) {
        $violations.Add("ALLOWLISTED FILE MISSING: $rel")
    }
    elseif (-not $found.ContainsKey($rel)) {
        $violations.Add("ALLOWLIST COUNT CHANGED for ${rel}: found 0, ratified $($allow[$rel].directives)")
    }
}

# --- SDK surface: zero platform sniffing, zero platform conditionals --------
$sdkSniffRx = [regex]::new(
    "process\.platform|navigator\.platform|navigator\.userAgent|\bos\.platform\s*\(|require\(\s*['""](?:node:)?os['""]|from\s+['""](?:node:)?os['""]",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
if (Test-Path 'sdk/typescript') {
    $tsFiles = Get-ChildItem sdk/typescript -Recurse -File `
        -Include '*.ts', '*.tsx', '*.js', '*.mjs', '*.cjs' |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|dist)[\\/]' }
    foreach ($file in $tsFiles) {
        $rel = Get-RelPath $file.FullName
        $lineNo = 0
        foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
            $lineNo++
            $m = $sdkSniffRx.Match($line)
            if ($m.Success) {
                $report.Add("${rel}:${lineNo}: $($m.Value)")
                $violations.Add("SDK PLATFORM SNIFFING (frozen zero) : ${rel}:${lineNo}: $($m.Value)")
            }
        }
    }
}
if (Test-Path 'sdk/pas2js') {
    $p2jFiles = Get-ChildItem sdk/pas2js -Recurse -File -Include '*.pas', '*.pp', '*.inc'
    foreach ($file in $p2jFiles) {
        $rel = Get-RelPath $file.FullName
        $lineNo = 0
        foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
            $lineNo++
            foreach ($hit in (Get-PlatformDirectiveMatches $line)) {
                $report.Add("${rel}:${lineNo}: $hit")
                $violations.Add("SDK PLATFORM CONDITIONAL (frozen zero) : ${rel}:${lineNo}: $hit")
            }
        }
    }
}

# --- report + verdict --------------------------------------------------------
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# CAP-7F platform-divergence sweep')
$lines.Add("# surface: src/** (minus src/platform/**), examples/07-quickjs/, examples/08-release/, tools/bundler/, tools/quickjs/, tools/pweb/, sdk/**")
$lines.Add('# every platform-conditional occurrence found:')
foreach ($r in $report) { $lines.Add($r) }
$lines.Add('#')
if ($violations.Count -eq 0) {
    $lines.Add('VERDICT: PASS (allowlist-only divergence)')
} else {
    $lines.Add("VERDICT: FAIL ($($violations.Count) violation(s))")
    foreach ($v in $violations) { $lines.Add("VIOLATION: $v") }
}
[System.IO.File]::WriteAllText(
    (Join-Path (Resolve-Path build/cap7f).Path 'divergence.txt'),
    (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))

if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Write-Host "VIOLATION: $v" }
    throw "CAP-7F divergence sweep FAILED: $($violations.Count) violation(s) (see build/cap7f/divergence.txt)"
}
Write-Host "[CAP-7F] divergence sweep PASS - $($report.Count) platform conditionals, all inside the ratified allowlist"
