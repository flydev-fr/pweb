# Canonical regeneration pipeline for the raw webview binding.
#
#   pwsh tools/regen-webview-binding.ps1 [-ChetCli <path\to\ChetCLI.exe>]
#
# Step 1: chetcli run src/lib/webview.chet   (deterministic, committed config)
# Step 2: committed post-process (this script, below): a pure text transform
#         that adds compiler directives chetcli cannot emit:
#           - a header comment recording the pinned upstream SHA (webview.lock)
#           - {$MODE OBJFPC}{$H+}   explicit mode instead of relying on -M
#           - {$PACKRECORDS C}      explicit C record layout (ABI, measured by
#                                   the paired probes in test/core/)
#           - the Darwin platform conditions, translated from Delphi's
#             conditional symbols to FPC's (CAP-7M0, see below)
#           - a trailing newline
#
# CAP-7M0 -- why the Darwin branches are rewritten here rather than in the
# chet config. ChetCLI is a Delphi tool and emits DELPHI conditional symbols
# for its [Platform.*] sections. For Win64 and Linux64 that is invisible,
# because WIN64 and LINUX happen to mean the same thing to both compilers.
# For macOS it is not: Delphi says MACOS64/CPUARM64, FPC says DARWIN/
# CPUAARCH64 (MEASURED against the same split mORMot relies on --
# mormot.defines.inc:316 uses {$ifdef DARWIN} for FPC and :522 {$ifdef MACOS}
# for Delphi; :601 shows CPUARM64 is the Delphi spelling of CPUAARCH64).
# Left as generated, both Darwin branches are dead under FPC and the unit
# stops at {$MESSAGE Error 'Unsupported platform'}.
#
# The declarations themselves stay untouched: this rewrite is confined to the
# two {$ELSEIF} lines of the platform block, is exact-match (a changed shape
# throws instead of silently matching nothing), and is idempotent in the same
# way the rest of step 2 is -- regeneration is always step 1 then step 2 over
# a fresh chetcli output. The alternative, hand-editing the generated unit,
# is forbidden.
#
# The generated unit is NEVER edited by hand; every regeneration runs this
# pipeline, and running it twice must produce byte-identical output.

param(
    [string]$ChetCli = 'C:\Users\badb\Documents\Embarcadero\Studio\Tools\chet-cli\ChetCLI.exe'
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Unit     = Join-Path $RepoRoot 'src\lib\pweb.lib.webview.pas'
$Chet     = Join-Path $RepoRoot 'src\lib\webview.chet'
$LockFile = Join-Path $RepoRoot 'webview.lock'

if (-not (Test-Path $ChetCli)) { throw "ChetCLI not found at $ChetCli (pass -ChetCli)" }
if (-not (Test-Path (Join-Path $RepoRoot 'deps\webview\core\include\webview\api.h'))) {
    throw 'pinned headers missing -- run tools/get-webview.ps1 first'
}

# --- pinned SHA from the lock (single source of truth) ------------------------
$Sha = $null
foreach ($line in Get-Content $LockFile) {
    if ($line.Trim() -match '^commit\s*=\s*([0-9a-f]{40})$') { $Sha = $Matches[1]; break }
}
if (-not $Sha) { throw 'webview.lock: no 40-char commit pin found' }

# --- step 1: generate ----------------------------------------------------------
& $ChetCli run $Chet
if ($LASTEXITCODE -ne 0) { throw "chetcli run failed with exit code $LASTEXITCODE" }

# --- step 2: deterministic post-process ---------------------------------------
$Text = [System.IO.File]::ReadAllText($Unit)

$Anchor = "{`$MINENUMSIZE 4}"
if (-not $Text.Contains($Anchor)) { throw "post-process anchor '$Anchor' not found -- chetcli output changed shape" }
if ($Text.Contains('PACKRECORDS')) { throw 'post-process appears to have already run on this file' }

$Replacement = @(
    "{ Generated from webview/webview @ $Sha"
    '  (pin recorded in webview.lock; regenerate ONLY via'
    '  tools/regen-webview-binding.ps1 -- never edit by hand). }'
    ''
    '{$MODE OBJFPC}{$H+}'
    $Anchor
    '{$PACKRECORDS C}'
) -join "`r`n"

$Text = $Text.Replace($Anchor, $Replacement)

# --- step 2b: Delphi platform symbols -> FPC platform symbols ------------------
# Exact-match, one occurrence each, both mandatory once [Platform.MacARM] and
# [Platform.MacIntel] are enabled in the chet config. `not Defined(IOS)` is
# kept verbatim from the generator: FPC defines DARWIN for iOS targets too,
# so the guard means the same thing on both compilers.
$PlatformRewrites = @(
    @{ From = '{$ELSEIF Defined(MACOS64) and Defined(CPUARM64) and not Defined(IOS)}'
       To   = '{$ELSEIF Defined(DARWIN) and Defined(CPUAARCH64) and not Defined(IOS)}' }
    @{ From = '{$ELSEIF Defined(MACOS64) and Defined(CPUX64) and not Defined(IOS)}'
       To   = '{$ELSEIF Defined(DARWIN) and Defined(CPUX64) and not Defined(IOS)}' }
)
foreach ($rw in $PlatformRewrites) {
    $hits = ([regex]::Matches($Text, [regex]::Escape($rw.From))).Count
    if ($hits -ne 1) {
        throw ("post-process expected exactly 1 occurrence of '$($rw.From)'," +
            " found $hits -- chetcli platform block changed shape")
    }
    $Text = $Text.Replace($rw.From, $rw.To)
}
# Both Delphi-only symbols, not just the first. MACOS64 and CPUARM64 are
# translated by two independent rewrites above, so checking only one leaves
# the other free to survive a shape change in the generator - and a surviving
# CPUARM64 branch is dead under FPC in exactly the same silent way.
foreach ($delphiOnly in 'MACOS64', 'CPUARM64') {
    if ($Text.Contains($delphiOnly)) {
        throw "post-process left a Delphi-only $delphiOnly condition in the unit"
    }
}
foreach ($required in 'DARWIN', 'CPUAARCH64') {
    if (-not $Text.Contains($required)) {
        throw "post-process did not produce the FPC symbol $required"
    }
}

# exactly one trailing newline after the final 'end.'
$Text = $Text.TrimEnd("`r", "`n") + "`r`n"

[System.IO.File]::WriteAllText($Unit, $Text, [System.Text.UTF8Encoding]::new($false))
Write-Host "regenerated + post-processed: $Unit (pin $Sha)"
