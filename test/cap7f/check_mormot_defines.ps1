# CAP-15B: the ALWAYS-FALSE CONDITIONAL, swept mechanically.
#
# `test/cap7f/check_divergence.ps1` counts platform conditionals against a
# ratified allowlist. It does not EVALUATE them, and it cannot: a count is
# the same whether the symbol is ever defined or not. This gate is the
# missing half, and it lives beside it for that reason.
#
# ---------------------------------------------------------------------------
# THE DEFECT, measured rather than imagined
# ---------------------------------------------------------------------------
#
# CAP-15B's mORMot transport first guarded its POSIX-only TLS import with
# `{$ifdef OSPOSIX}`. `OSPOSIX` is a mORMot symbol, defined by
# `deps/mormot2/src/mormot.defines.inc`, and NO unit under `src/` includes
# that file — so the conditional was always false. The unit compiled cleanly,
# linked no TLS layer, and every `https` request then died at the handshake
# with mORMot's own "TLS support not compiled - try including
# mormot.lib.openssl11 in your project".
#
# NOTHING A COMPILER SAYS CAN CATCH THAT. A dead region is not a warning; it
# is silence. It was found only because a live exchange was measured against
# a real server before the push, and the next one will not be so lucky.
#
# ---------------------------------------------------------------------------
# THE RULE
# ---------------------------------------------------------------------------
#
#   A compiler directive in a Pascal file that does NOT include
#   `mormot.defines.inc` may not test a symbol that only that file defines.
#
# The symbol set is DERIVED FROM THE PIN, not hand-written: every
# `{$define X}` in the pinned `mormot.defines.inc`. It is COMMITTED as
# `test/cap7f/mormot-defines.tsv` so this sweep stays checkout-only - the job
# it runs in has the repository and nothing else - and the derivation is
# re-done and compared wherever `deps/mormot2` IS present, which is every
# platform leg. A mORMot repin that adds a define therefore widens this gate,
# and one that changes the set without regenerating the file turns four legs
# red rather than passing quietly.
#
# FOUR SYMBOLS ARE EXCLUDED, and the exclusion is measured rather than
# assumed. FPC predefines a `CPU<target>` family of its own, and four members
# of that family also appear in mORMot's define list because mORMot defines
# them for DELPHI:
#
#   CPU64, CPU32   a probe generated from the pin - one `{$ifdef}` per
#                  symbol, compiled WITHOUT `mormot.defines.inc` - reported
#                  exactly `CPU64` on both `linux-x86_64` and
#                  `windows-x86_64` (2026-09-10, FPC 3.2.3 / 3.2.2). `CPU32`
#                  is its 32-bit twin and the probe was 64-bit only
#   CPUAARCH64,    mORMot defines these only inside its DELPHI branch
#   CPUARM         (`{$ifdef CPUARM64}` / `{$ifdef CPUARM32}`, beside the
#                  comment "not the same meaning on Delphi and FPC/mORMot").
#                  Under FPC they are the compiler's own, and this repository
#                  MEASURES that on every hosted macOS arm64 run:
#                  `PWebCliHostArch` reports `arm64` from a bare
#                  `{$ifdef CPUAARCH64}` in a file that includes no mORMot
#                  header, and `src/lib/pweb.lib.webview.pas` selects the
#                  arm64 dylib from another. Were they dead, the arm64 leg
#                  would report `other` and fail to load its library
#
# `CPUX64`, `CPUX86_64` and `CPUAMD64` never enter the set at all: the pin
# tests them but never `{$define}`s them, and the same probe confirmed all
# three are FPC's own on both x86_64 targets. `CPUINTEL` and `CPUX86` ARE
# mORMot's alone and stay in the set. Every other symbol in the pin is
# mORMot's alone.
#
# Checkout-only: no build, no toolchain, no network.
#
# Emits build/cap7f/mormot-defines-sweep.txt and exits nonzero on any violation.
#
# Usage: pwsh test/cap7f/check_mormot_defines.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot
New-Item -ItemType Directory -Force build/cap7f | Out-Null

$report = New-Object System.Collections.Generic.List[string]
$violations = New-Object System.Collections.Generic.List[string]

# --- the symbol set ---------------------------------------------------------
#
# DERIVED FROM THE PIN, and committed beside this gate so the sweep can run in
# a job that carries no `deps/` tree. `test/cap7f/mormot-defines.tsv` is DATA,
# not a hand-written list:
#
#   * wherever `deps/mormot2` IS present - every platform leg, and any
#     developer checkout that has fetched it - this gate RE-DERIVES the set
#     from the pin and REFUSES a mismatch by name, so a mORMot repin that adds
#     or removes a define cannot pass without regenerating the file in the
#     same commit;
#   * where it is NOT present - the checkout-only aggregate job, which is
#     exactly where this sweep belongs beside `check_divergence` - the
#     committed list is used and the report says so.
#
# The first hosted run of this gate went red for precisely the absence this
# handles: the aggregate job checks out the repository and nothing else, and
# the gate threw on a missing `mormot.defines.inc`. A checkout-only gate that
# needs a dependency is not a checkout-only gate.
$listPath = 'test/cap7f/mormot-defines.tsv'
if (-not (Test-Path $listPath)) { throw "[cap7f] $listPath is absent" }
$listLines = @([System.IO.File]::ReadAllLines($listPath))
$pinSha = ''
$committed = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($l in $listLines) {
    if ($l -match '^#\s*pin-sha256\s+([0-9a-f]{64})\s*$') { $pinSha = $Matches[1]; continue }
    if ($l -match '^\s*#' -or $l.Trim() -eq '') { continue }
    [void]$committed.Add($l.Trim())
}
if ($pinSha -eq '') { throw "[cap7f] $listPath carries no pin-sha256 line" }

$definesInc = 'deps/mormot2/src/mormot.defines.inc'
$symbols = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($s in $committed) { [void]$symbols.Add($s) }
$derivedFrom = 'the committed list (deps/mormot2 is absent, as it is in the checkout-only job)'
if (Test-Path $definesInc) {
    $defText = [System.IO.File]::ReadAllText($definesInc)
    $live = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in [regex]::Matches($defText, '\{\$define\s+([A-Za-z_][A-Za-z0-9_]*)\s*\}',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        [void]$live.Add($m.Groups[1].Value)
    }
    $added = @($live | Where-Object { -not $committed.Contains($_) } | Sort-Object)
    $removed = @($committed | Where-Object { -not $live.Contains($_) } | Sort-Object)
    if ($added.Count -gt 0 -or $removed.Count -gt 0) {
        $violations.Add(("THE COMMITTED DEFINE SET IS STALE: $listPath has " +
            "$($committed.Count) symbol(s) and the pin has $($live.Count) -- " +
            "added: $($added -join ',') removed: $($removed -join ',') -- " +
            'regenerate the file in the same commit as the repin, so the ' +
            'sweep widens with mORMot instead of quietly staying where it was'))
    }
    $symbols = $live
    $derivedFrom = "$definesInc (re-derived and compared against the committed list)"
}
$derived = $symbols.Count
# MEASURED, not assumed - see the header
foreach ($alsoFpc in 'CPU32', 'CPU64', 'CPUAARCH64', 'CPUARM') {
    [void]$symbols.Remove($alsoFpc)
}
$report.Add("symbols: $derived from $derivedFrom ($($symbols.Count) after the four FPC CPU-target members)")

# --- the surface -----------------------------------------------------------
# src/** is the framework, tools/** the CLI and the bundler, examples/** the
# shipped hosts, and tools/templates/** the two programs `pweb create`
# generates. A generated program is somebody else's source tomorrow, which is
# exactly why it is swept here rather than trusted.
$surface = @(
    (Get-ChildItem src -Recurse -File -Include '*.pas', '*.lpr', '*.inc'),
    (Get-ChildItem tools -Recurse -File -Include '*.pas', '*.lpr', '*.inc'),
    (Get-ChildItem examples -Recurse -File -Include '*.pas', '*.lpr', '*.inc' |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|dist)[\\/]' })
) | ForEach-Object { $_ }

# BOTH FPC directive spellings, exactly as check_divergence scans them: the
# brace form and the parenthesis-star comment form, which is a legal
# directive a brace-only scanner would silently wave through.
$directiveRx = [regex]::new('\{\$\s*(?:ifdef|ifndef|elseif|if|endif)\b[^}]*\}',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$directiveParenRx = [regex]::new('\(\*\$\s*(?:ifdef|ifndef|elseif|if|endif)\b[^*]*\*\)',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$includeRx = [regex]::new('\{\$\s*(?:I|INCLUDE)\s+mormot\.defines\.inc\s*\}',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

$scanned = 0
$withInclude = 0
$hits = 0
foreach ($file in $surface) {
    $rel = ($file.FullName.Substring($repoRoot.Length).TrimStart('\', '/')) `
        -replace '\\', '/'
    $text = [System.IO.File]::ReadAllText($file.FullName)
    $scanned++
    if ($includeRx.IsMatch($text)) {
        # this file DOES include the pin, so every symbol in it is live
        $withInclude++
        continue
    }
    $lineNo = 0
    foreach ($line in ($text -split "`r?`n")) {
        $lineNo++
        foreach ($rx in @($directiveRx, $directiveParenRx)) {
            foreach ($d in $rx.Matches($line)) {
                foreach ($w in [regex]::Matches($d.Value, '[A-Za-z_][A-Za-z0-9_]*')) {
                    if (-not $symbols.Contains($w.Value)) { continue }
                    $hits++
                    $violations.Add(("ALWAYS-FALSE CONDITIONAL: ${rel}:${lineNo}: " +
                        "$($d.Value) tests the mORMot symbol $($w.Value), and this " +
                        'file does not include mormot.defines.inc - the region is ' +
                        'dead and no compiler will say so'))
                }
            }
        }
    }
}
$report.Add("scanned $scanned Pascal file(s); $withInclude include the pin and are exempt")
$report.Add("always-false conditionals: $hits")

# --- verdict ----------------------------------------------------------------
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# CAP-15B always-false-conditional sweep')
foreach ($r in $report) { $lines.Add("# $r") }
if ($violations.Count -eq 0) {
    $lines.Add("MORMOT_DEFINES_PASS derived=$derived scanned=$scanned exempt=$withInclude hits=0")
} else {
    $lines.Add("VERDICT: FAIL ($($violations.Count) violation(s))")
    foreach ($v in $violations) { $lines.Add("VIOLATION: $v") }
}
[System.IO.File]::WriteAllText(
    (Join-Path $repoRoot 'build/cap7f/mormot-defines-sweep.txt'),
    (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
foreach ($r in $report) { Write-Host "[cap7f] $r" }
if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Write-Host $v }
    throw "CAP-15B always-false-conditional sweep FAILED: $($violations.Count) violation(s)"
}
Write-Host ("MORMOT_DEFINES_PASS derived=$derived scanned=$scanned " +
    "exempt=$withInclude hits=0")
