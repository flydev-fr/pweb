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
#           - a trailing newline
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

# exactly one trailing newline after the final 'end.'
$Text = $Text.TrimEnd("`r", "`n") + "`r`n"

[System.IO.File]::WriteAllText($Unit, $Text, [System.Text.UTF8Encoding]::new($false))
Write-Host "regenerated + post-processed: $Unit (pin $Sha)"
