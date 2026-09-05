# CAP-6b3 gates over the real
# dist/windows/fixed-runtime/PWebRelease-FixedRuntime-Setup.exe
# (CAP-6b4 renamed the artifact away from the appcompat-shimmed
# setup.exe basename; every assertion below is unchanged and stays the
# no-regression proof).
# Safe by construction on ANY host: this profile provisions nothing,
# executes no Microsoft installer and touches no machine-wide state -
# it deploys a bundled runtime tree under the per-user install dir and
# the app selects that tree in its own process. A host that already has
# an Evergreen runtime is in fact the INTERESTING host here: it is what
# makes the no-fallback proof meaningful.
#
#   1. pin coherence: the compiled helper's --pin facts equal the lock
#      facts the build exported (a rename on either side fails HERE)
#   2. staged-tree manifest re-verification through the native streamed
#      digest (the build wrote it; this proves it still holds)
#   3. silent per-user install FROM AN ISOLATED DIRECTORY containing
#      ONLY the profile's own setup binary (packaged independence: no
#      repo, no CWD, no cache
#      can contribute anything), bounded, with /LOG; the log must show
#      the ACL helper's exit 0 and must contain NO provisioning marker
#      of any kind (WV2PROV_*) - this profile provisions nothing
#   4. installed-layout exact set BY RELATIVE PATH (nesting fails): the
#      release triple + uninstaller + EVERY staged runtime file, and
#      nothing else; neither Evergreen installer, no loose frontend
#      file outside the runtime tree, and the ACL helper never installed
#   5. the AppContainer ACL on the INSTALLED tree verifies BY SID, the
#      five INSTALLED critical binaries carry the ratified Authenticode
#      subject, and the installed root passes the app's own pre-create
#      validation
#   6. the INSTALLED tree matches the build-time manifest byte for byte
#   7. installed-app smoke from an unrelated CWD: the fixed runtime is
#      SELECTED, its identity is OBSERVED equal to the pin, and the
#      browser process image our own PID spawned lies INSIDE the
#      bundled tree. A nil webview_create is only ever a SKIP once the
#      Evergreen CONTROL host has failed the same way on the same
#      machine - otherwise it is a fixed-runtime defect and this gate
#      fails
#   8. NO-FALLBACK negative legs: with the bundled browser image (then
#      the loader) removed, the app must FAIL before webview_create
#      with a typed marker - even though this host has a usable
#      Evergreen runtime that a fallback would have used
#   9. silent uninstall leaves no installed launchable app, no runtime
#      tree and no per-user (HKCU) uninstall registry key
#  10. ABORT PROBE: the TEST-ONLY setup whose post-install helper always
#      fails must exit NONZERO and leave NO installed app, NO runtime
#      tree and no HKCU uninstall key - with INNO'S OWN rollback proven
#      in the log ("Rolling back changes" / "Uninstallation process
#      succeeded"), not a hand-rolled cleanup. The failing gate writes
#      no verdict file, so Setup cannot find the last [Files] entry's
#      external source and aborts itself
#
# CAP-10E PARAMETERISED THE INSTALL DIRECTORY, and parameterised is the
# operative word: this is the SAME gate body, run a second time at a
# directory whose name carries a space and a non-ASCII character, rather
# than a copy of it that could drift away from the original. E4 of that
# shard is exactly the ten legs above with one variable changed, and the
# interesting ones are 5 (the ACL verified BY SID on an accented path), 7
# (the installed app resolves its bundled runtime through the kernel image
# path and answers 42) and 9 (the uninstall leaves nothing, with the
# path-scoped drain doing the waiting).
#
# Usage: pwsh -File test/cap6b3/run_fixed_setup_gates.ps1
#        pwsh -File test/cap6b3/run_fixed_setup_gates.ps1 -InstallLeaf 'Programs\PWebRelease étude'
param(
    # relative to %LOCALAPPDATA%. The default is the ratified CAP-6b3 path
    # and is passed to Setup exactly as before - no /DIR= at all - so the
    # ordinary run's command line is byte-for-byte what it always was.
    [string]$InstallLeaf = 'Programs\PWebRelease',
    # where this run's row record goes; CAP-10E reads it for the aggregate
    [string]$RecordFile = ''
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Push-Location $RepoRoot
try {
    foreach ($pre in 'dist/windows/fixed-runtime/PWebRelease-FixedRuntime-Setup.exe',
                     'build/cap6b3/bin/pwebwv2fixed.exe',
                     'build/cap6b3/tree.manifest',
                     'build/cap6b3/lockfacts.psd1') {
        if (-not (Test-Path $pre)) {
            throw ("missing precondition: $pre -- run " +
                'test/cap6b3/build_fixed_setup.ps1 first')
        }
    }
    $facts = Import-PowerShellDataFile (Resolve-Path build/cap6b3/lockfacts.psd1).Path
    $Helper = (Resolve-Path build/cap6b3/bin/pwebwv2fixed.exe).Path
    $SetupExe = (Resolve-Path dist/windows/fixed-runtime/PWebRelease-FixedRuntime-Setup.exe).Path
    $Manifest = (Resolve-Path build/cap6b3/tree.manifest).Path
    $RuntimeDir = $facts.RuntimeDir
    if (-not (Test-Path $RuntimeDir)) {
        throw "staged runtime dir missing: $RuntimeDir"
    }
    $InstallDir = Join-Path $env:LOCALAPPDATA $InstallLeaf
    # /DIR= is passed ONLY when the caller asked for somewhere else, so the
    # ratified run's command line does not change at all
    $DefaultLeaf = 'Programs\PWebRelease'
    $DirArgs = if ($InstallLeaf -cne $DefaultLeaf) { @("/DIR=$InstallDir") } else { @() }
    $InstallNonAscii = (($InstallDir.ToCharArray() |
        Where-Object { [int]$_ -gt 127 }).Count -gt 0)
    Write-Host ("CAP-6b3 install directory: $InstallDir " +
        "(non-ASCII=$InstallNonAscii, /DIR= passed=$($DirArgs.Count -gt 0))")
    # per-user (PrivilegesRequired=lowest) Inno uninstall key for AppId
    # {7C3E9A1B-...} - the literal AppId from tools/setup/pwebappsetup.issi
    $UninstKey = ('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
        '{7C3E9A1B-5D24-4F68-A0C9-2B8E6D4F1A57}_is1')
    $InstalledRuntime = Join-Path $InstallDir 'runtime\webview2'
    # CAP-10E: unset until gate 7 decides; a record written without it would
    # claim nothing rather than claiming falsely
    $FixedSmokeVerdict = 'unmeasured'
    $InstalledTree = Join-Path $InstalledRuntime $facts.TreeName
    New-Item -ItemType Directory -Force build/cap6b3 | Out-Null

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
                $childPid = $proc.Id
                $proc.Kill($true)
                # the post-kill confirmation wait is bounded too: an
                # unkillable child must fail LOUDLY, never hang the gate
                if (-not $proc.WaitForExit(30000)) {
                    throw ("$What exceeded ${TimeoutMs}ms; kill UNCONFIRMED - " +
                        "child pid $childPid still alive after 30000ms")
                }
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

    # --- 1) pin coherence between the helper and the exported lock facts -----
    $pin = Invoke-Bounded $Helper @('--pin') 60000 'helper --pin'
    if ($pin.Code -ne 0) { throw "helper --pin exited $($pin.Code): $($pin.Out)" }
    # WV2FIXED_PIN carries COMPILED-IN constants and WV2FIXED_VALIDATED
    # carries OBSERVED tree facts under different keys, so this grep can
    # never be satisfied by an observation of some other tree
    if ($pin.Out -notmatch '(?m)^WV2FIXED_PIN ') {
        throw "helper --pin emitted no WV2FIXED_PIN line: $($pin.Out)"
    }
    foreach ($expect in "version=$($facts.FixedVersion)",
                        "treename=$($facts.TreeName)",
                        'loader=WebView2Loader.dll',
                        "manifest=$($facts.ManifestTag)") {
        if ($pin.Out -cnotmatch [regex]::Escape($expect)) {
            throw "helper --pin lost '$expect': $($pin.Out)"
        }
    }
    Write-Host 'CAP-6b3 gate 1 PASS (helper pin facts equal the exported lock facts)'

    # --- 2) the staged tree still matches its build-time manifest -------------
    $m = Invoke-Bounded $Helper @('--manifest-verify', $RuntimeDir, $Manifest) `
        600000 'staged manifest verify'
    if (($m.Code -ne 0) -or ($m.Out -notmatch 'WV2FIXED_RESULT outcome=Ok')) {
        throw "staged tree does not match its manifest (exit $($m.Code)): $($m.Out)"
    }
    Write-Host ("CAP-6b3 gate 2 PASS (staged tree matches the deterministic " +
        "manifest: $($facts.TreeFiles) file(s), $($facts.TreeBytes) byte(s))")

    # --- 3) silent per-user install from an ISOLATED directory ---------------
    # packaged independence: the dir holds ONLY this profile's setup
    # binary, lives outside
    # the repo, and is the process CWD - nothing but the embedded payload
    # can contribute a byte to the install
    if (Test-Path $InstallDir) {
        # a stale tree from an earlier failed run must not fake a PASS
        Remove-Item -Recurse -Force $InstallDir
    }
    $Isolated = Join-Path ([System.IO.Path]::GetTempPath()) `
        "pweb-cap6b3-isolated-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force $Isolated | Out-Null
    $log = Join-Path $RepoRoot 'build/cap6b3/setup-install.log'
    if (Test-Path $log) { Remove-Item -Force $log }
    try {
        $IsolatedName = Split-Path -Leaf $SetupExe
        Copy-Item $SetupExe (Join-Path $Isolated $IsolatedName)
        $contents = @(Get-ChildItem $Isolated -Force | ForEach-Object Name)
        if (($contents -join ',') -cne $IsolatedName) {
            throw "isolated dir is not exactly [$IsolatedName]: $($contents -join ', ')"
        }
        $r = Invoke-Bounded (Join-Path $Isolated $IsolatedName) (@('/VERYSILENT',
            '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/LOG=$log") + $DirArgs) 1200000 `
            'silent fixed setup' $Isolated
        if ($r.Code -ne 0) {
            if (Test-Path $log) { Get-Content $log | Select-Object -Last 40 | Write-Host }
            throw "silent fixed setup exited $($r.Code)"
        }
    }
    finally {
        if (Test-Path $Isolated) { Remove-Item -Recurse -Force $Isolated }
    }
    if (-not (Test-Path $log)) { throw 'setup produced no log' }
    $logText = Get-Content $log -Raw
    if ($logText -notmatch 'PWEB_WV2FIXED exit=0') {
        throw 'setup log does not show the ACL helper exit 0'
    }
    if ($logText -notmatch 'WV2FIXED_RESULT outcome=Ok step=none') {
        throw 'setup log does not show the ACL helper Ok verdict'
    }
    if ($logText -match 'WV2PROV_') {
        throw 'FIXED INVARIANT BROKEN: a provisioning marker appears in the setup log'
    }
    if ($logText -notmatch 'PWEB_WV2FIXED verdict written') {
        throw 'setup log does not show the gate writing its success verdict'
    }
    # the verdict file is the gate's signal to Setup, not application
    # content: deleteafterinstall must keep it out of the install dir
    $verdictLeft = Join-Path $InstallDir 'pweb-fixed-runtime.verdict'
    if (Test-Path $verdictLeft) {
        throw "the gate's verdict file was left installed: $verdictLeft"
    }
    Write-Host ('CAP-6b3 gate 3 PASS (silent install from isolated dir exit 0; ' +
        'ACL applied and verified by SID in the log; verdict written and not ' +
        'installed; zero provisioning)')

    # --- 4) installed-layout exact set BY RELATIVE PATH -----------------------
    # policy: paths relative to the install dir (so any unexpected nesting
    # fails, not just an unexpected basename), compared byte-exact
    # case-sensitively - Inno installs with the exact staged casing
    if (-not (Test-Path $InstallDir)) { throw "install dir missing: $InstallDir" }
    $rootLen = (Resolve-Path $InstallDir).Path.Length + 1
    # -Force on both sides: ISCC's recursesubdirs embeds hidden files, so
    # a hidden entry must be counted in BOTH sets or this exact-set proof
    # fails opaquely instead of naming a real defect
    $files = @(Get-ChildItem $InstallDir -Recurse -File -Force |
        ForEach-Object { $_.FullName.Substring($rootLen) } | Sort-Object)
    $stagedLen = ((Resolve-Path $RuntimeDir).Path.TrimEnd('\') + '\').Length
    $expectedRuntime = @(Get-ChildItem $RuntimeDir -Recurse -File -Force |
        ForEach-Object { 'runtime\webview2\' + $_.FullName.Substring($stagedLen) })
    $expected = @('app.pwb', 'releaseapp.exe', 'unins000.dat',
        'unins000.exe', 'webview.dll') + $expectedRuntime | Sort-Object
    if (($files -join "`n") -cne ($expected -join "`n")) {
        $missing = @($expected | Where-Object { $files -cnotcontains $_ })
        $extra = @($files | Where-Object { $expected -cnotcontains $_ })
        throw ("installed layout is not the exact relative-path set: " +
            "$($missing.Count) missing [$(($missing | Select-Object -First 5) -join ', ')], " +
            "$($extra.Count) unexpected [$(($extra | Select-Object -First 5) -join ', ')]")
    }
    $loose = @($files |
        Where-Object { -not $_.StartsWith('runtime\', [StringComparison]::Ordinal) } |
        Where-Object { $_ -match '\.(html|css|js|map|json)$' })
    if ($loose) {
        throw "loose frontend file(s) installed: $($loose -join ', ')"
    }
    foreach ($banned in $facts.BootFile, $facts.StandaloneFile,
                        'pwebwv2fixed.exe') {
        if ($files -contains $banned) {
            throw "'$banned' was INSTALLED into the app directory"
        }
    }
    Write-Host ("CAP-6b3 gate 4 PASS (exact-set relative-path layout: triple + " +
        "uninstaller + $($expectedRuntime.Count) runtime file(s); no installer, " +
        'no helper, no loose frontend left behind)')

    # --- 5) the AppContainer ACL on the INSTALLED tree, verified BY SID -------
    $a = Invoke-Bounded $Helper @('--acl-verify', $InstalledTree) 60000 `
        'installed ACL verify'
    Write-Host $a.Out
    if (($a.Code -ne 0) -or ($a.Out -notmatch 'WV2FIXED_RESULT outcome=Ok')) {
        throw "installed tree ACL verification failed (exit $($a.Code)): $($a.Out)"
    }
    foreach ($sid in 'S-1-15-2-1', 'S-1-15-2-2') {
        if ($a.Out -cnotmatch [regex]::Escape($sid)) {
            throw "the ACL verdict does not name $sid (localized name parsing?)"
        }
    }
    Write-Host 'CAP-6b3 gate 5 PASS (installed tree grants both AppContainer SIDs, by SID)'

    # --- 5b) the five critical binaries that LANDED carry the ratified
    # --- signature, and the app's own pre-create validation accepts the
    # --- installed root (the same code path every launch runs) ---------------
    $sg = Invoke-Bounded $Helper @('--verify-signers', $InstalledRuntime,
        $facts.FixedSubject) 120000 'installed signer verify'
    Write-Host $sg.Out
    if (($sg.Code -ne 0) -or ($sg.Out -notmatch 'WV2FIXED_SIGNERS ')) {
        throw ("the INSTALLED critical binaries failed the signer axis " +
            "(exit $($sg.Code)): $($sg.Out)")
    }
    if ($sg.Out -cnotmatch [regex]::Escape($facts.FixedSubject)) {
        throw "the signer verdict does not name the ratified subject: $($sg.Out)"
    }
    $vd = Invoke-Bounded $Helper @('--validate', $InstalledRuntime) 120000 `
        'installed tree validate'
    Write-Host $vd.Out
    if (($vd.Code -ne 0) -or
        ($vd.Out -notmatch 'WV2FIXED_RESULT outcome=Ok step=none')) {
        throw ("the installed runtime root failed the app's own pre-create " +
            "validation (exit $($vd.Code)): $($vd.Out)")
    }
    if ($vd.Out -cnotmatch [regex]::Escape("version=$($facts.FixedVersion)")) {
        throw "the validation verdict does not observe the pin: $($vd.Out)"
    }
    Write-Host ('CAP-6b3 gate 5b PASS (installed critical binaries signed by ' +
        "the ratified subject; installed root passes the app's own validation)")

    # --- 6) the INSTALLED tree matches the build-time manifest ----------------
    $m = Invoke-Bounded $Helper @('--manifest-verify', $InstalledRuntime, $Manifest) `
        600000 'installed manifest verify'
    if (($m.Code -ne 0) -or ($m.Out -notmatch 'WV2FIXED_RESULT outcome=Ok')) {
        throw ("the INSTALLED runtime tree does not match the build-time " +
            "manifest (exit $($m.Code)): $($m.Out)")
    }
    Write-Host 'CAP-6b3 gate 6 PASS (installed tree is byte-identical to the built tree)'

    # --- 7) installed-app smoke from an unrelated CWD, WATCHING the browser --
    # the app is launched with Start-Process instead of the bounded helper
    # so this gate can observe, from the OUTSIDE, which msedgewebview2.exe
    # image our own process actually spawned - the second half of the
    # ratified identity proof (the first half is the app's own OBSERVED
    # get_BrowserVersionString): both must point INSIDE the bundled tree
    $marker = 'releaseapp: app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS'
    $smokeOut = Join-Path $RepoRoot 'build/cap6b3/smoke-installed.log'
    $smokeErr = Join-Path $RepoRoot 'build/cap6b3/smoke-installed.err.log'
    foreach ($stale in $smokeOut, $smokeErr) {
        if (Test-Path $stale) { Remove-Item -Force $stale }
    }
    $env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'
    # a HOSTILE inherited override: the app must overwrite it outright
    $env:WEBVIEW2_BROWSER_EXECUTABLE_FOLDER = 'C:\pweb-cap6b3-hostile-inherited'
    $seen = @{}
    try {
        $p = Start-Process -FilePath (Join-Path $InstallDir 'releaseapp.exe') `
            -WorkingDirectory ([System.IO.Path]::GetTempPath()) `
            -RedirectStandardOutput $smokeOut -RedirectStandardError $smokeErr `
            -PassThru -WindowStyle Minimized
        for ($i = 0; $i -lt 150; $i++) {
            Start-Sleep -Milliseconds 400
            foreach ($proc in @(Get-CimInstance Win32_Process `
                        -Filter "Name='msedgewebview2.exe'" `
                        -ErrorAction SilentlyContinue)) {
                if (($proc.ParentProcessId -eq $p.Id) -and
                    (-not [string]::IsNullOrEmpty($proc.ExecutablePath))) {
                    $seen[$proc.ExecutablePath] = $true
                }
            }
            if ($p.HasExited) { break }
        }
        if (-not $p.WaitForExit(180000)) {
            $p.Kill($true)
            throw 'the installed app did not exit within 180s and was killed'
        }
        $smokeCode = $p.ExitCode
    }
    finally {
        Remove-Item Env:\WEBVIEW2_BROWSER_EXECUTABLE_FOLDER -ErrorAction SilentlyContinue
    }
    $smokeText = ((Get-Content $smokeOut -Raw -ErrorAction SilentlyContinue) +
        (Get-Content $smokeErr -Raw -ErrorAction SilentlyContinue))
    Write-Host $smokeText
    foreach ($image in $seen.Keys) { Write-Host "BROWSERPROCESS=$image" }
    if ($smokeText -notmatch 'FIXED RUNTIME SELECTED') {
        throw 'the installed app did not select the bundled fixed runtime'
    }
    if ($smokeText -match 'FIXED RUNTIME REFUSED') {
        throw "the installed app REFUSED its own bundled runtime: $smokeText"
    }
    # an IDENTITY refusal is its own marker and must never fall through
    # to the generic failure branch: it is the one signal that says the
    # WebView opened on something other than the pinned runtime
    if ($smokeText -match 'FIXED RUNTIME IDENTITY REFUSED') {
        throw ('IDENTITY REFUSED: the WebView that opened is not the pinned ' +
            "runtime - $smokeText")
    }
    # the containment compare must be directory-anchored: a sibling
    # directory sharing the tree path as a plain string prefix
    # (…x64-evil\) would otherwise pass as "inside the tree"
    $treePrefix = $InstalledTree.TrimEnd('\') + '\'
    if (($smokeCode -eq 0) -and ($smokeText -match [regex]::Escape($marker))) {
        if ($smokeText -cnotmatch [regex]::Escape(
                "FIXED RUNTIME IDENTITY OK $($facts.FixedVersion)")) {
            throw ("the app did not OBSERVE the pinned runtime identity " +
                "$($facts.FixedVersion): $smokeText")
        }
        if ($seen.Count -eq 0) {
            throw ('the app returned 42 but no msedgewebview2.exe child was ' +
                'ever observed - the browser-image half of the identity proof ' +
                'cannot be voided silently')
        }
        $outside = @($seen.Keys | Where-Object {
            -not $_.StartsWith($treePrefix, [StringComparison]::OrdinalIgnoreCase) })
        if ($outside) {
            throw ("NO-FALLBACK BROKEN: the browser process ran from OUTSIDE " +
                "the bundled tree: $($outside -join ', ')")
        }
        $FixedSmokeVerdict = '42'
        Write-Host ('CAP-6b3 gate 7 PASS (installed app selected the bundled ' +
            "runtime, OBSERVED $($facts.FixedVersion), spawned $($seen.Count) " +
            'browser image(s) INSIDE the bundled tree and returned 42)')
    }
    elseif ($smokeText -match 'webview_create \(returned nil') {
        # In FIXED mode a nil webview_create is NOT self-evidently a
        # session problem: the runtime is bundled, validated AND
        # selected, so a nil could equally be a defect in the very
        # selection mechanism this gate exists to prove. Decide it with
        # a CONTROL: the Evergreen-profile host on the same machine, in
        # the same session. If the control opens a WebView, the fixed
        # nil is a defect and this gate FAILS.
        $control = Join-Path $RepoRoot 'build/cap6/release/releaseapp.exe'
        if (-not (Test-Path $control)) {
            throw ('fixed webview_create returned nil and the Evergreen ' +
                "control host is missing ($control) - the SKIP cannot be " +
                'justified; run test/cap6/run_cap6_gates.ps1 first')
        }
        $env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'
        $c = Invoke-Bounded $control @() 180000 'Evergreen control host' `
            ([System.IO.Path]::GetTempPath())
        Write-Host $c.Out
        if ($c.Out -notmatch 'webview_create \(returned nil') {
            throw ('FIXED-RUNTIME DEFECT: webview_create returned nil for the ' +
                'fixed profile while the Evergreen control host on this same ' +
                "machine opened a WebView (control exit $($c.Code)) - the " +
                'bundled-runtime selection is broken, not the session')
        }
        $FixedSmokeVerdict = 'skip_no_session'
        Write-Host ("CAP-6b3 gate 7 SKIP (fixed runtime selected, but the " +
            "Evergreen CONTROL host also failed with webview_create nil on " +
            "this machine - no desktop session; fixed exit $smokeCode)")
    }
    else {
        throw "installed-app smoke failed (exit $smokeCode; see build/cap6b3/smoke-installed.log)"
    }

    # --- 8) NO-FALLBACK negative legs ----------------------------------------
    # this host has a usable Evergreen runtime (the CAP-6b1/6b2 gates prove
    # it); a broken bundled tree must therefore FAIL, never silently run on
    # Evergreen. Each leg removes one required member, runs the app, and
    # restores it.
    function Test-BrokenTreeLeg {
        param([string]$Victim, [string]$ExpectStep, [string]$What)
        $backup = "$Victim.cap6b3-bak"
        Move-Item -LiteralPath $Victim -Destination $backup -Force
        try {
            $env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'
            $b = Invoke-Bounded (Join-Path $InstallDir 'releaseapp.exe') @() `
                120000 "broken-tree app ($What)" ([System.IO.Path]::GetTempPath())
            Write-Host $b.Out
            if ($b.Code -eq 0) {
                throw "NO-FALLBACK BROKEN: the app succeeded with $What removed"
            }
            if ($b.Out -notmatch 'FIXED RUNTIME REFUSED') {
                throw "the app did not emit the typed refusal with $What removed: $($b.Out)"
            }
            if ($b.Out -notmatch "step=$ExpectStep") {
                throw "the refusal named the wrong step (expected $ExpectStep): $($b.Out)"
            }
            if ($b.Out -match [regex]::Escape($marker)) {
                throw "NO-FALLBACK BROKEN: the 42 marker appeared with $what removed"
            }
            if ($b.Out -match 'FIXED RUNTIME IDENTITY OK') {
                throw "NO-FALLBACK BROKEN: a WebView opened with $What removed"
            }
        }
        finally {
            Move-Item -LiteralPath $backup -Destination $Victim -Force
        }
    }
    Test-BrokenTreeLeg (Join-Path $InstalledTree 'msedgewebview2.exe') `
        'tree_incomplete' 'the bundled browser image'
    Test-BrokenTreeLeg (Join-Path $InstalledRuntime 'WebView2Loader.dll') `
        'tree_incomplete' 'the bundled loader'
    # and the app works again once the tree is whole
    $env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'
    $again = Invoke-Bounded (Join-Path $InstallDir 'releaseapp.exe') @() `
        180000 'restored releaseapp' ([System.IO.Path]::GetTempPath())
    if ($again.Out -notmatch 'FIXED RUNTIME SELECTED') {
        throw "restoring the tree did not restore the selection: $($again.Out)"
    }
    Write-Host ('CAP-6b3 gate 8 PASS (a broken bundled tree FAILS closed on a host ' +
        'with a usable Evergreen runtime - no fallback, twice - and the restored ' +
        'tree selects again)')

    # --- 9) silent uninstall leaves no launchable app ------------------------
    #
    # TEARDOWN FIRST, AND IT IS NOT AN OPTIMISATION. Gates 7 and 8 ran three
    # applications that each spawned a browser image INSIDE the bundled tree,
    # and nothing between them and this point waited for those processes to
    # exit. Windows cannot delete a mapped image, the Inno uninstaller reports
    # success anyway, and the filesystem poll below then waits 300 seconds for
    # a directory that will never empty. MEASURED on hosted run 33163186945,
    # twice on one commit, leaving 11 files and then a different 8 - the
    # changing subset is the signature.
    #
    # The drain is scoped BY EXECUTABLE IMAGE PATH to this installation. The
    # runner's unrelated Evergreen processes - which CAP-6b1, CAP-6b2 and
    # gate 8's own no-fallback proof all depend on - are outside these roots
    # and are never considered, let alone terminated.
    #
    # It REFUSES rather than continues: if the matching set is still non-empty
    # the uninstaller is not run at all, because what that would test is not
    # uninstall cleanup.
    . (Join-Path $PSScriptRoot 'wv2procdrain.ps1')
    # first the applications this gate launched: each was started bounded and
    # waited on, so this must already be empty - and if it is not, that is a
    # defect of its own and not something to uninstall over
    Assert-PWebProcessDrained -Root $InstallDir -Names @('releaseapp.exe') `
        -What 'installed test application' -GraceMs 4000 -TimeoutMs 60000 |
        Out-Null
    # then the browser tree they spawned, under the Fixed Runtime root
    Assert-PWebProcessDrained -Root $InstalledRuntime `
        -Names @('msedgewebview2.exe') -What 'bundled Fixed Runtime browser' `
        -GraceMs 8000 -TimeoutMs 90000 | Out-Null

    $unins = Join-Path $InstallDir 'unins000.exe'
    # the Inno uninstaller respawns a copy of itself and the original
    # process exits early: poll for the result, bounded
    $u = Invoke-Bounded $unins @('/VERYSILENT', '/SUPPRESSMSGBOXES',
        '/NORESTART') 600000 'silent uninstall'
    if ($u.Code -ne 0) { throw "silent uninstall exited $($u.Code)" }
    # the poll below VERIFIES cleanup. It is no longer the mechanism that
    # waits for the browser to shut down - that is the drain above - so a
    # residue here now means the uninstaller genuinely left something.
    $deadline = [DateTime]::UtcNow.AddSeconds(300)
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
            # residue AFTER a proven-empty drain is a different fact from
            # residue before one, so say which: re-enumerate the scoped
            # process set and report both halves rather than only the files
            $still = @(Get-PWebScopedProcess -Names @('msedgewebview2.exe', 'releaseapp.exe') `
                -Root $InstallDir)
            $procRows = @($still | ForEach-Object {
                $sid = 0; $simg = ''
                try { $sid = [int]$_.ProcessId } catch { $sid = 0 }
                try { $simg = [string]$_.ExecutablePath } catch { $simg = '' }
                "pid=$sid image=$simg"
            })
            $procNote = if ($procRows.Count -gt 0) {
                " ; $($procRows.Count) matching process(es) STILL present: $($procRows -join '; ')"
            } else {
                ' ; no matching Fixed Runtime process remains, so the residue is the uninstaller''s'
            }
            throw ("uninstall left $($left.Count) file(s) behind: " +
                "$(($left | Select-Object -First 5) -join ', ')$procNote")
        }
    }
    foreach ($gone in 'releaseapp.exe', 'app.pwb', 'webview.dll') {
        if (Test-Path (Join-Path $InstallDir $gone)) {
            throw "uninstall left a launchable component: $gone"
        }
    }
    if (Test-Path $InstalledTree) {
        throw "uninstall left the bundled runtime tree behind: $InstalledTree"
    }
    # the per-user uninstall registry entry must be gone too (bounded
    # poll: the respawned uninstaller removes it near the very end)
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    while (([DateTime]::UtcNow -lt $deadline) -and (Test-Path $UninstKey)) {
        Start-Sleep -Milliseconds 500
    }
    if (Test-Path $UninstKey) {
        throw "uninstall left the HKCU uninstall registry key: $UninstKey"
    }
    Write-Host ('CAP-6b3 gate 9 PASS (silent uninstall removed the app, the whole ' +
        'runtime tree and the HKCU uninstall key)')

    # --- 10) ABORT PROBE: a failing post-install gate installs nothing -------
    # the ratified CAP-6b1 abort-probe pattern: the TEST-ONLY setup built
    # with an always-fail stub through the documented PWEB_ACL_HELPER hook.
    # It runs LAST, after gate 9 proved the machine is clean, so a leftover
    # from this leg can never be mistaken for a real install.
    $AbortProbe = $facts.AbortProbeExe
    if (-not (Test-Path $AbortProbe)) {
        throw "abort-probe setup missing: $AbortProbe -- rebuild"
    }
    if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
    $abortLog = Join-Path $RepoRoot 'build/cap6b3/setup-abort.log'
    if (Test-Path $abortLog) { Remove-Item -Force $abortLog }
    $ab = Invoke-Bounded $AbortProbe @('/VERYSILENT', '/SUPPRESSMSGBOXES',
        '/NORESTART', '/SP-', "/LOG=$abortLog") 1200000 'abort-probe setup'
    Write-Host "abort-probe setup exit=$($ab.Code)"
    # a failing gate writes no verdict file, so Setup cannot find the
    # last [Files] entry's source and aborts. The exit code is Inno's
    # own (the Abort default of its Abort/Retry/Ignore box under
    # /SUPPRESSMSGBOXES), so this asserts NONZERO rather than pinning a
    # number the pinned ISCC could legitimately change.
    if ($ab.Code -eq 0) {
        throw 'ABORT CHAIN BROKEN: the abort-probe setup exited 0'
    }
    if (-not (Test-Path $abortLog)) { throw 'abort-probe setup produced no log' }
    $abortText = Get-Content $abortLog -Raw
    if ($abortText -notmatch 'WV2FIXED_RESULT outcome=Failed step=signers') {
        throw "abort-probe log does not show the helper failure verdict: see $abortLog"
    }
    if ($abortText -notmatch 'PWEB_WV2FIXED exit=6') {
        throw 'abort-probe log does not show the helper nonzero exit'
    }
    if ($abortText -notmatch 'PWEB_WV2FIXED REFUSED') {
        throw 'abort-probe log does not show the gate refusing with a reason'
    }
    if ($abortText -match 'PWEB_WV2FIXED verdict written') {
        throw 'ABORT CHAIN BROKEN: a failing gate still wrote its verdict file'
    }
    # the rollback must be INNO'S OWN, not something this profile does
    # by hand: hand-rolled cleanup races the installer and was measured
    # to produce an incidental EFileError instead of a real abort
    foreach ($proof in 'Rolling back changes',
                       'Uninstallation process succeeded') {
        if ($abortText -notmatch [regex]::Escape($proof)) {
            throw ("abort-probe log does not prove Inno's own rollback ran " +
                "('$proof' missing): see $abortLog")
        }
    }
    if ($abortText -match 'WV2PROV_') {
        throw 'FIXED INVARIANT BROKEN: a provisioning marker appears in the abort log'
    }
    foreach ($banned in $facts.BootFile, $facts.StandaloneFile) {
        if ($abortText -match [regex]::Escape($banned)) {
            throw "FIXED INVARIANT BROKEN: '$banned' appears in the abort log"
        }
    }
    # nothing launchable, and no runtime tree, may survive a failed gate
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    while (([DateTime]::UtcNow -lt $deadline) -and (Test-Path $InstallDir)) {
        Start-Sleep -Milliseconds 500
    }
    if (Test-Path $InstallDir) {
        $left = @(Get-ChildItem $InstallDir -Recurse -File -Force `
            -ErrorAction SilentlyContinue | ForEach-Object Name)
        if ($left) {
            throw ("ABORT CHAIN BROKEN: $($left.Count) file(s) survived a " +
                "failed post-install gate: $(($left | Select-Object -First 5) -join ', ')")
        }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (([DateTime]::UtcNow -lt $deadline) -and (Test-Path $UninstKey)) {
        Start-Sleep -Milliseconds 500
    }
    if (Test-Path $UninstKey) {
        throw "ABORT CHAIN BROKEN: the HKCU uninstall key survived: $UninstKey"
    }
    Write-Host ("CAP-6b3 gate 10 PASS (a failing gate wrote no verdict; setup " +
        "exited $($ab.Code) and INNO'S OWN rollback removed everything: no " +
        '{app}, no runtime tree, no HKCU uninstall key, no provisioning path)')

    if ($env:GITHUB_STEP_SUMMARY) {
        ("### CAP-6b3 fixed-runtime setup gates`nPASS - pin coherence, staged and " +
         'installed tree manifests, isolated-dir install with the ACL applied and ' +
         'verified by SID, exact-set layout, observed pinned identity, ' +
         'no-fallback negative legs, clean uninstall incl. registry') |
            Out-File -Append $env:GITHUB_STEP_SUMMARY
    }
    # CAP-10E E4: the record this run made, written whenever the caller asked
    # for one. It carries the ONE fact the aggregate needs from here - what a
    # fixed-runtime profile installed under this directory did - plus the
    # directory itself, so a reader can see that the accented run really was
    # accented rather than trusting the invocation.
    if ($RecordFile -ne '') {
        $rec = [ordered]@{
            schema                      = 1
            install_dir                 = $InstallDir
            install_dir_non_ascii       = $(if ($InstallNonAscii) { 'true' } else { 'false' })
            install_dir_arg_passed      = $(if ($DirArgs.Count -gt 0) { 'true' } else { 'false' })
            fixed_profile_smoke         = "$FixedSmokeVerdict"
            fixed_profile_nonascii_dir  = $(if ($InstallNonAscii) {
                "$FixedSmokeVerdict" } else { 'not_measured_here' })
            verdict                     = 'PASS'
        }
        New-Item -ItemType Directory -Force (Split-Path -Parent $RecordFile) | Out-Null
        [System.IO.File]::WriteAllText($RecordFile,
            (($rec | ConvertTo-Json -Depth 3) + "`n"),
            [System.Text.UTF8Encoding]::new($false))
        Write-Host ($rec | ConvertTo-Json -Depth 3)
    }
    Write-Host 'CAP6B3_SETUP_GATES_PASS'
}
finally {
    Pop-Location
}
