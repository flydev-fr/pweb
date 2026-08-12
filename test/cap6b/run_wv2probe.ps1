# CAP-6b0 host WebView2 detection smoke. Compiles test/cap6b/wv2probe.pas
# with the fpc on PATH and runs it once on THIS machine. The outcome is
# diagnostic evidence, never a runtime requirement: an unavailable
# runtime (or a structured detection_error) is a SKIP; only a crashed
# probe - the detector contract forbids raising - or a missing
# WV2DETECT line fails. The detected version goes to the GitHub step
# summary when one exists. CI never downloads or installs a runtime
# because of what this reports.
#
# Usage: pwsh -File test/cap6b/run_wv2probe.ps1

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Push-Location $RepoRoot
try {
    New-Item -ItemType Directory -Force build/cap6b/fpc,
        build/cap6b/bin | Out-Null
    fpc -MObjFPC -Sh -B -FUbuild/cap6b/fpc -FEbuild/cap6b/bin `
        -Fusrc/platform/windows `
        -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib `
        test/cap6b/wv2probe.pas
    if ($LASTEXITCODE -ne 0) { throw 'wv2probe compile failed' }

    $out = & build/cap6b/bin/wv2probe.exe 2>&1 | Out-String
    $code = $LASTEXITCODE
    Write-Host $out
    $out | Out-File -Encoding utf8 build/cap6b/probe.log

    $line = (($out -split "`r?`n") |
        Where-Object { $_ -match '^WV2DETECT status=' } |
        Select-Object -First 1)
    if (($code -eq 0) -and ($line -match 'status=available')) {
        $verdict = "DETECTED - $line"
    }
    elseif (($code -eq 0) -and ($line -match 'status=unavailable')) {
        $verdict = "SKIP - no WebView2 runtime detected on this host ($line)"
    }
    elseif (($code -eq 0) -and ($line -match 'status=detection_error')) {
        # ratified: a structured detection_error is a SKIP, but only
        # when it carries its diagnostic (the detector contract says
        # every detection_error names the Win32 code behind it)
        $diag = (($out -split "`r?`n") |
            Where-Object { $_ -match '^WV2DETECT_DIAG \S' } |
            Select-Object -First 1)
        if ($diag) {
            $verdict = "SKIP - structured detection_error reported ($line)"
        }
        else {
            $verdict = "FAIL - detection_error without a diagnostic line (exit $code)"
        }
    }
    else {
        $verdict = "FAIL - probe crashed or emitted no WV2DETECT line (exit $code)"
    }
    if ($env:GITHUB_STEP_SUMMARY) {
        "### CAP-6b0 WebView2 runtime detection (diagnostic)`n$verdict" |
            Out-File -Append $env:GITHUB_STEP_SUMMARY
    }
    Write-Host "CAP-6b0 detection verdict: $verdict"
    if ($verdict.StartsWith('FAIL')) { exit 1 }
}
finally {
    Pop-Location
}
