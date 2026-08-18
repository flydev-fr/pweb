# CAP-7F: platform-divergence sweep over the PRODUCTION surface (src/**,
# examples/08-release/, tools/bundler/) against an explicit, ratified
# allowlist. Checkout-only: no build, no toolchain - it runs in the
# cap7-aggregate job and on any dev host.
#
# WHAT COUNTS AS A DIVERGENCE: a compiler conditional whose condition names
# a platform symbol ({$ifdef DARWIN}, {$IF Defined(WIN64)}, {$ifndef LINUX},
# {$endif OSWINDOWS} tags included), and - in the SDKs - runtime platform
# sniffing (process.platform and friends). Profile conditionals
# (PWEB_FIXED_RUNTIME) are deliberately NOT platform divergence.
#
# THE ALLOWLIST IS EXACT, per file, by directive COUNT:
#   - a platform conditional in any file NOT on the allowlist fails,
#     naming file:line - this is what keeps the frozen zero-conditional
#     core units (scheduler, rpc intf/mormot/support, capabilities,
#     webview binding/intf, assets intf/support/zip, both SDKs) frozen;
#   - a count CHANGE in an allowlisted file fails too, in EITHER direction:
#     growth is a new divergence, shrinkage means the ratified ground truth
#     moved and the allowlist must be re-ratified in the same commit.
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
$directiveRx = [regex]::new('\{\$\s*(?:ifdef|ifndef|elseif|if|else|endif)\b[^}]*\}',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$platformRx = [regex]::new(
    '\b(WIN32|WIN64|WINDOWS|OSWINDOWS|MSWINDOWS|LINUX|DARWIN|UNIX|POSIX|BSD|FREEBSD|IOS|OSX|MACOS|HAIKU|CPUX86_64|CPUX64|CPUX86|CPUAARCH64|CPUARM64|CPUARM)\b',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

# file (repo-relative, forward slashes) -> exact ratified directive count
$allow = @{
    'examples/08-release/releaseapp.pas' = 32   # the 13 platform regions
    'src/lib/pweb.lib.webview.pas'       = 4    # LIB_WEBVIEW selection block
    'src/assets/pweb.assets.folder.pas'  = 10   # Darwin F_GETPATH / Windows wide-API split
    'src/assets/pweb.assets.bundle.pas'  = 6    # I/O mechanism only (ratified)
    'tools/bundler/pwebbundle.pas'       = 6    # Windows wide-API walk (ledgered)
}

# the frozen zero-conditional core, named so a hit there says what it broke
$frozenCore = @(
    'src/rpc/pweb.rpc.scheduler.pas', 'src/rpc/pweb.rpc.intf.pas',
    'src/rpc/pweb.rpc.mormot.pas', 'src/rpc/pweb.rpc.support.pas',
    'src/security/pweb.capabilities.pas',
    'src/webview/pweb.webview.binding.pas', 'src/webview/pweb.webview.intf.pas',
    'src/assets/pweb.assets.intf.pas', 'src/assets/pweb.assets.support.pas',
    'src/assets/pweb.assets.zip.pas'
)

function Get-RelPath([string]$FullName) {
    $rel = $FullName.Substring($repoRoot.Length).TrimStart('\', '/')
    return $rel -replace '\\', '/'
}

# --- Pascal surface ---------------------------------------------------------
$pascalRoots = @('src', 'examples/08-release', 'tools/bundler')
$pascalFiles = foreach ($root in $pascalRoots) {
    if (Test-Path $root) {
        Get-ChildItem $root -Recurse -File -Include '*.pas', '*.pp', '*.inc' |
            Where-Object { (Get-RelPath $_.FullName) -notmatch '^src/platform/' }
    }
}

$found = @{}
foreach ($file in $pascalFiles) {
    $rel = Get-RelPath $file.FullName
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
        $lineNo++
        foreach ($m in $directiveRx.Matches($line)) {
            if ($platformRx.IsMatch($m.Value)) {
                if (-not $found.ContainsKey($rel)) { $found[$rel] = @() }
                $found[$rel] += "${rel}:${lineNo}: $($m.Value)"
            }
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
    elseif ($hits.Count -ne $allow[$rel]) {
        $violations.Add(("ALLOWLIST COUNT CHANGED for ${rel}: found $($hits.Count), " +
            "ratified $($allow[$rel]) -- re-ratify the allowlist in the same commit, lines:"))
        foreach ($h in $hits) { $violations.Add("  $h") }
    }
}
# an allowlisted file with ZERO findings is a count change too
foreach ($rel in ($allow.Keys | Sort-Object)) {
    if (-not (Test-Path $rel)) {
        $violations.Add("ALLOWLISTED FILE MISSING: $rel")
    }
    elseif (-not $found.ContainsKey($rel)) {
        $violations.Add("ALLOWLIST COUNT CHANGED for ${rel}: found 0, ratified $($allow[$rel])")
    }
}

# --- SDK surface: zero platform sniffing, zero platform conditionals --------
$sdkSniffRx = [regex]::new(
    "process\.platform|navigator\.platform|navigator\.userAgent|\bos\.platform\s*\(|require\(\s*['""](?:node:)?os['""]|from\s+['""](?:node:)?os['""]",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
if (Test-Path 'sdk/typescript') {
    $tsFiles = Get-ChildItem sdk/typescript -Recurse -File `
        -Include '*.ts', '*.tsx', '*.js', '*.mjs', '*.cjs' |
        Where-Object { $_.FullName -notmatch '\\(node_modules|dist)\\' }
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
            foreach ($m in $directiveRx.Matches($line)) {
                if ($platformRx.IsMatch($m.Value)) {
                    $report.Add("${rel}:${lineNo}: $($m.Value)")
                    $violations.Add("SDK PLATFORM CONDITIONAL (frozen zero) : ${rel}:${lineNo}: $($m.Value)")
                }
            }
        }
    }
}

# --- report + verdict --------------------------------------------------------
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# CAP-7F platform-divergence sweep')
$lines.Add("# surface: src/** (minus src/platform/**), examples/08-release/, tools/bundler/, sdk/**")
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
