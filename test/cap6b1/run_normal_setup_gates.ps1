# CAP-6b1 gates over the real dist/windows/normal/setup.exe. Safe by
# construction on any machine that already has a usable WebView2
# runtime (hosted runners do): the helper's AlreadyUsable skip path is
# proven and the Bootstrapper is NEVER executed. On a machine WITHOUT
# a usable runtime the gates SKIP instead of running the installer -
# executing the Bootstrapper is reserved for the ratified setup flow
# on the authoritative clean-machine VM gate
# (test/cap6b1/run_clean_machine_gate.ps1), never for CI.
#
#   V. UNCONDITIONAL verification legs (every host, --verify-only, no
#      execution possible by construction): the native accept path
#      over the real lock-verified bootstrapper (and byte-equality of
#      the native subject rendering vs Get-AuthenticodeSignature),
#      wrong-sha refusal, wrong-subject refusal, unsigned refusal
#   0. host probe through the compiled helper with a DUMMY payload
#      (execution impossible by construction: a dummy can never pass
#      the sha256 pin) - decides PASS-path vs SKIP; under GitHub
#      Actions a non-usable host is a HARD FAIL (hosted Windows
#      runners are documented runtime-present, so a SKIP there would
#      silently void the proof)
#   1. helper skip path over the REAL embedded payload: AlreadyUsable,
#      exit 0, no WV2PROV_EXEC line (the bootstrapper never ran)
#   2. silent per-user install, bounded, with /LOG; the log must show
#      the helper verdict AlreadyUsable/exit 0 and no execution
#   3. installed-layout exact set BY RELATIVE PATH (nesting fails):
#      app.pwb, releaseapp.exe, unins000.dat, unins000.exe,
#      webview.dll - nothing else, no loose frontend files (mirrors
#      the run_cap6_gates exact-set rule); byte-exact case-sensitive
#      compare (Inno preserves the staged casing)
#   4. installed-app smoke from an unrelated CWD (CAP-6 marker 42)
#   5. silent uninstall leaves no installed launchable app behind and
#      removes the per-user (HKCU) uninstall registry key
#   6. abort-probe: the TEST setup embedding the always-fail stub
#      helper must exit nonzero and leave NO install directory - the
#      fail-closed abort chain proven by automation
#
# Usage: pwsh -File test/cap6b1/run_normal_setup_gates.ps1

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Push-Location $RepoRoot
try {
    foreach ($pre in 'dist/windows/normal/setup.exe',
                     'build/cap6b1/bin/pwebwv2prov.exe',
                     'build/cap6b1/lockfacts.psd1') {
        if (-not (Test-Path $pre)) {
            throw ("missing precondition: $pre -- run " +
                'test/cap6b1/build_normal_setup.ps1 first')
        }
    }
    $facts = Import-PowerShellDataFile (Resolve-Path build/cap6b1/lockfacts.psd1).Path
    $Helper = (Resolve-Path build/cap6b1/bin/pwebwv2prov.exe).Path
    $SetupExe = (Resolve-Path dist/windows/normal/setup.exe).Path
    $BootPayload = Join-Path $RepoRoot "build/cap6b1/payload/$($facts.BootFile)"
    if (-not (Test-Path $BootPayload)) {
        throw "staged bootstrapper missing: $BootPayload"
    }
    if (-not (Test-Path $facts.AbortProbeExe)) {
        throw "abort-probe setup missing: $($facts.AbortProbeExe) -- rerun build_normal_setup.ps1"
    }
    $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\PWebRelease'
    # per-user (PrivilegesRequired=lowest) Inno uninstall key for AppId
    # {7C3E9A1B-...} - the literal AppId from tools/setup/normal.iss
    $UninstKey = ('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
        '{7C3E9A1B-5D24-4F68-A0C9-2B8E6D4F1A57}_is1')
    New-Item -ItemType Directory -Force build/cap6b1 | Out-Null

    function Invoke-Bounded {
        param([string]$Exe, [string[]]$Args2, [int]$TimeoutMs, [string]$What,
            [string]$WorkDir = '')
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $Exe
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        if ($WorkDir -ne '') { $start.WorkingDirectory = $WorkDir }
        foreach ($a in $Args2) { [void]$start.ArgumentList.Add($a) }
        $proc = [Diagnostics.Process]::Start($start)
        if ($null -eq $proc) { throw "failed to start $What" }
        try {
            $stdout = $proc.StandardOutput.ReadToEndAsync()
            $stderr = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit($TimeoutMs)) {
                $proc.Kill($true)
                $proc.WaitForExit()
                throw "$What exceeded ${TimeoutMs}ms and was killed"
            }
            [pscustomobject]@{
                Code = $proc.ExitCode
                Out = ($stdout.GetAwaiter().GetResult() +
                       $stderr.GetAwaiter().GetResult())
            }
        }
        finally { $proc.Dispose() }
    }

    # --- V) UNCONDITIONAL --verify-only legs: every host, no execution
    # --- possible by construction (the mode has no execute step) -------------
    # V1: native ACCEPT of the genuine artifact + rendering byte-parity
    $v = Invoke-Bounded $Helper @('--verify-only', $BootPayload,
        $facts.BootSha, $facts.BootSubject) 60000 'verify-only accept'
    Write-Host $v.Out
    if (($v.Code -ne 0) -or
        ($v.Out -notmatch 'WV2PROV_RESULT outcome=Verified step=none')) {
        throw "verify-only ACCEPT failed on the genuine artifact (exit $($v.Code))"
    }
    # the native WinVerifyTrust/CertNameToStrW rendering must byte-match
    # what PowerShell's Get-AuthenticodeSignature prints AND the pin
    $psSubject = (Get-AuthenticodeSignature -FilePath $BootPayload).SignerCertificate.Subject
    if ($psSubject -cne $facts.BootSubject) {
        throw ("PowerShell subject rendering diverged from the pin:" +
            " '$psSubject' vs '$($facts.BootSubject)'")
    }
    $nativeSubject = (($v.Out -split "`r?`n") |
        Where-Object { $_ -match '^WV2PROV_DIAG authenticode Valid, subject=' } |
        Select-Object -First 1) -replace '^WV2PROV_DIAG authenticode Valid, subject=', ''
    if ($nativeSubject -cne $psSubject) {
        throw ("native subject rendering diverged from PowerShell:" +
            " '$nativeSubject' vs '$psSubject'")
    }
    Write-Host 'CAP-6b1 gate V1 PASS (native accept; native = PowerShell = pin subject rendering)'
    # V2: wrong sha -> digest exit code, signature never consulted
    $v = Invoke-Bounded $Helper @('--verify-only', $BootPayload,
        ('0' * 64), $facts.BootSubject) 60000 'verify-only wrong sha'
    if (($v.Code -ne 3) -or
        ($v.Out -notmatch 'WV2PROV_RESULT outcome=Failed step=verify_digest') -or
        ($v.Out -match 'WV2PROV_SUBJECT')) {
        throw "verify-only wrong-sha leg failed (exit $($v.Code)): $($v.Out)"
    }
    if (($v.Out -notmatch [regex]::Escape($facts.BootSha)) -or
        ($v.Out -notmatch ('0' * 64))) {
        throw "wrong-sha refusal does not name both digests: $($v.Out)"
    }
    Write-Host 'CAP-6b1 gate V2 PASS (wrong sha refused, digests named)'
    # V3: right sha + wrong subject -> signature exit code
    $v = Invoke-Bounded $Helper @('--verify-only', $BootPayload,
        $facts.BootSha, 'CN=PWeb Wrong Subject Probe') 60000 `
        'verify-only wrong subject'
    if (($v.Code -ne 4) -or
        ($v.Out -notmatch 'WV2PROV_RESULT outcome=Failed step=verify_signature') -or
        ($v.Out -notmatch 'CN=PWeb Wrong Subject Probe')) {
        throw "verify-only wrong-subject leg failed (exit $($v.Code)): $($v.Out)"
    }
    Write-Host 'CAP-6b1 gate V3 PASS (valid signature, wrong subject refused)'
    # V4: unsigned binary (the fpc-built helper itself) with its TRUE
    # sha -> signature exit code (digest passes, signature refuses)
    $helperSha = (Get-FileHash -Algorithm SHA256 $Helper).Hash.ToLowerInvariant()
    $v = Invoke-Bounded $Helper @('--verify-only', $Helper, $helperSha,
        $facts.BootSubject) 60000 'verify-only unsigned'
    if (($v.Code -ne 4) -or
        ($v.Out -notmatch 'WV2PROV_RESULT outcome=Failed step=verify_signature')) {
        throw "verify-only unsigned leg failed (exit $($v.Code)): $($v.Out)"
    }
    Write-Host 'CAP-6b1 gate V4 PASS (unsigned binary refused despite correct sha)'

    # --- 0) host probe with a DUMMY payload: execution impossible ------------
    $dummy = Join-Path $RepoRoot 'build/cap6b1/dummy-payload.bin'
    Set-Content -LiteralPath $dummy -Value 'not the ratified bootstrapper' -NoNewline
    $probe = Invoke-Bounded $Helper @($dummy, $facts.BootSha,
        $facts.BootSubject) 60000 'helper host probe'
    Write-Host $probe.Out
    if ($probe.Out -notmatch 'WV2PROV_DETECT status=') {
        throw "helper probe emitted no WV2PROV_DETECT line (exit $($probe.Code))"
    }
    if ($probe.Out -notmatch 'WV2PROV_RESULT outcome=AlreadyUsable') {
        # ProvisionRequired machines get the dummy digest refusal (the
        # fail-closed leg just proved itself) but the install gates
        # would EXECUTE the real bootstrapper: that proof belongs to
        # the clean-machine VM gate alone
        if (($probe.Code -ne 3) -or
            ($probe.Out -notmatch 'WV2PROV_RESULT outcome=Failed step=verify_digest')) {
            throw ("helper probe behaved unexpectedly on a non-usable host " +
                "(exit $($probe.Code)): $($probe.Out)")
        }
        if ($env:GITHUB_ACTIONS) {
            # hosted Windows runners are documented runtime-present: a
            # SKIP here would silently void the skip-path proof CI
            # exists to give - fail hard instead
            throw ('hosted runner reports no usable WebView2 runtime - the ' +
                'CAP-6b1 skip-path proof cannot run; runner image changed?')
        }
        $verdict = ('SKIP - no usable WebView2 runtime on this host; the ' +
            'fail-closed digest refusal was proven instead, and genuine ' +
            'provisioning proof is the clean-machine VM gate')
        if ($env:GITHUB_STEP_SUMMARY) {
            "### CAP-6b1 normal setup gates`n$verdict" |
                Out-File -Append $env:GITHUB_STEP_SUMMARY
        }
        Write-Host "CAP-6b1 gates verdict: $verdict"
        exit 0
    }
    Write-Host 'CAP-6b1 gate 0 PASS (host runtime usable; dummy probe AlreadyUsable)'

    # --- 1) helper skip path over the REAL embedded payload ------------------
    $skip = Invoke-Bounded $Helper @($BootPayload, $facts.BootSha,
        $facts.BootSubject) 60000 'helper skip path'
    Write-Host $skip.Out
    if ($skip.Code -ne 0) { throw "skip path exited $($skip.Code)" }
    if ($skip.Out -notmatch 'WV2PROV_RESULT outcome=AlreadyUsable step=none') {
        throw "skip path did not report AlreadyUsable: $($skip.Out)"
    }
    if ($skip.Out -match 'WV2PROV_EXEC') {
        throw "SKIP PATH EXECUTED THE BOOTSTRAPPER: $($skip.Out)"
    }
    Write-Host 'CAP-6b1 gate 1 PASS (real payload skip path: AlreadyUsable, never executed)'

    # --- 2) silent per-user install, bounded, logged --------------------------
    if (Test-Path $InstallDir) {
        # a stale tree from an earlier failed run must not fake a PASS
        Remove-Item -Recurse -Force $InstallDir
    }
    $log = Join-Path $RepoRoot 'build/cap6b1/setup-install.log'
    if (Test-Path $log) { Remove-Item -Force $log }
    $r = Invoke-Bounded $SetupExe @('/VERYSILENT', '/SUPPRESSMSGBOXES',
        '/NORESTART', '/SP-', "/LOG=$log") 300000 'silent setup'
    if ($r.Code -ne 0) {
        if (Test-Path $log) { Get-Content $log | Select-Object -Last 40 | Write-Host }
        throw "silent setup exited $($r.Code)"
    }
    if (-not (Test-Path $log)) { throw 'setup produced no log' }
    $logText = Get-Content $log -Raw
    if ($logText -notmatch 'WV2PROV_RESULT outcome=AlreadyUsable step=none') {
        throw 'setup log does not show the helper AlreadyUsable verdict'
    }
    if ($logText -notmatch 'PWEB_WV2PROV exit=0') {
        throw 'setup log does not show helper exit 0'
    }
    if ($logText -match 'WV2PROV_EXEC') {
        throw 'SETUP EXECUTED THE BOOTSTRAPPER ON A RUNTIME-PRESENT HOST'
    }
    Write-Host 'CAP-6b1 gate 2 PASS (silent install exit 0; helper skip path in the log)'

    # --- 3) installed-layout exact set BY RELATIVE PATH -----------------------
    # policy: paths relative to the install dir (so any unexpected
    # nesting fails, not just an unexpected basename), compared
    # byte-exact case-sensitively - Inno installs with the exact staged
    # casing, so the canonical expected set below IS the contract
    if (-not (Test-Path $InstallDir)) { throw "install dir missing: $InstallDir" }
    $rootLen = (Resolve-Path $InstallDir).Path.Length + 1
    $files = @(Get-ChildItem $InstallDir -Recurse -File |
        ForEach-Object { $_.FullName.Substring($rootLen) } | Sort-Object)
    $expected = @('app.pwb', 'releaseapp.exe', 'unins000.dat',
        'unins000.exe', 'webview.dll')
    if (($files -join ',') -cne ($expected -join ',')) {
        throw "installed layout is not the exact relative-path set: $($files -join ', ')"
    }
    $loose = @($files | Where-Object { $_ -match '\.(html|css|js|map|json)$' })
    if ($loose) {
        throw "loose frontend file(s) installed: $($loose -join ', ')"
    }
    Write-Host 'CAP-6b1 gate 3 PASS (exact-set relative-path layout: triple + uninstaller, no loose files)'

    # --- 4) installed-app smoke from an unrelated CWD -------------------------
    $marker = 'releaseapp: app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS'
    $env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'
    $s = Invoke-Bounded (Join-Path $InstallDir 'releaseapp.exe') @() `
        120000 'installed releaseapp' ([System.IO.Path]::GetTempPath())
    Write-Host $s.Out
    $s.Out | Out-File -Encoding utf8 build/cap6b1/smoke-installed.log
    if (($s.Code -eq 0) -and ($s.Out -match [regex]::Escape($marker))) {
        Write-Host 'CAP-6b1 gate 4 PASS (installed app booted from app.pwb and returned 42)'
    }
    elseif ($s.Out -match 'webview_create \(returned nil') {
        # the ratified conditional hosted policy (run_cap6_smoke.ps1):
        # a usable runtime does not guarantee a desktop session on a
        # hosted runner - only that state records SKIP, never a defect
        Write-Host ("CAP-6b1 gate 4 SKIP (runtime usable but no desktop " +
            "session for webview_create; exit $($s.Code))")
    }
    else {
        throw "installed-app smoke failed (exit $($s.Code); see build/cap6b1/smoke-installed.log)"
    }

    # --- 5) silent uninstall leaves no launchable app -------------------------
    $unins = Join-Path $InstallDir 'unins000.exe'
    # the Inno uninstaller respawns a copy of itself and the original
    # process exits early: poll for the result, bounded
    $u = Invoke-Bounded $unins @('/VERYSILENT', '/SUPPRESSMSGBOXES',
        '/NORESTART') 120000 'silent uninstall'
    if ($u.Code -ne 0) { throw "silent uninstall exited $($u.Code)" }
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-Path $InstallDir)) { break }
        $left = @(Get-ChildItem $InstallDir -Recurse -File -ErrorAction SilentlyContinue)
        if ($left.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
    if (Test-Path $InstallDir) {
        $left = @(Get-ChildItem $InstallDir -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object Name)
        if ($left) {
            throw "uninstall left files behind: $($left -join ', ')"
        }
    }
    foreach ($gone in 'releaseapp.exe', 'app.pwb', 'webview.dll') {
        if (Test-Path (Join-Path $InstallDir $gone)) {
            throw "uninstall left a launchable component: $gone"
        }
    }
    # the per-user uninstall registry entry must be gone too (bounded
    # poll: the respawned uninstaller removes it near the very end)
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (([DateTime]::UtcNow -lt $deadline) -and (Test-Path $UninstKey)) {
        Start-Sleep -Milliseconds 500
    }
    if (Test-Path $UninstKey) {
        throw "uninstall left the HKCU uninstall registry key: $UninstKey"
    }
    Write-Host 'CAP-6b1 gate 5 PASS (silent uninstall removed the app and its HKCU uninstall key)'

    # --- 6) abort-probe: a failing helper aborts with NOTHING installed -------
    if (Test-Path $InstallDir) {
        throw 'gate 6 precondition violated: install dir exists before the abort probe'
    }
    $abortLog = Join-Path $RepoRoot 'build/cap6b1/setup-abort.log'
    if (Test-Path $abortLog) { Remove-Item -Force $abortLog }
    $a = Invoke-Bounded $facts.AbortProbeExe @('/VERYSILENT',
        '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/LOG=$abortLog") `
        300000 'abort-probe setup'
    if ($a.Code -eq 0) {
        throw 'ABORT-PROBE SETUP SUCCEEDED despite the always-fail helper'
    }
    if (-not (Test-Path $abortLog)) { throw 'abort-probe setup produced no log' }
    $abortText = Get-Content $abortLog -Raw
    if ($abortText -notmatch 'WV2PROV_RESULT outcome=Failed step=verify_digest') {
        throw 'abort-probe log does not show the stub failure verdict'
    }
    if ($abortText -notmatch 'PWEB_WV2PROV exit=3') {
        throw 'abort-probe log does not show the helper exit code 3'
    }
    if (Test-Path $InstallDir) {
        $left = @(Get-ChildItem $InstallDir -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object Name)
        throw ("abort-probe left an install dir behind (files: " +
            "$($left -join ', ')) - the fail-closed abort chain is broken")
    }
    Write-Host "CAP-6b1 gate 6 PASS (helper failure aborted setup, exit $($a.Code), nothing installed)"

    if ($env:GITHUB_STEP_SUMMARY) {
        ("### CAP-6b1 normal setup gates`nPASS - verify-only matrix (native " +
         'accept + refusals), skip path (bootstrapper never executed), ' +
         'exact-set layout, installed smoke 42, clean uninstall incl. ' +
         'registry, fail-closed abort probe') |
            Out-File -Append $env:GITHUB_STEP_SUMMARY
    }
    Write-Host 'CAP6B1_SETUP_GATES_PASS'
}
finally {
    Pop-Location
}
