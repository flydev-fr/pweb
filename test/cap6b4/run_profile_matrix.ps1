# CAP-6b4 PROFILE MATRIX - the CAP-13 acceptance evidence.
#
# Three installers, ONE product: one AppId, one install directory, one
# HKCU profile marker, three mutually exclusive modes. This gate proves
# the integration by DOING it - a single optimal chain of real installs,
# real switches, real refusals and real uninstalls on this machine.
#
# Rows covered, in chain order (each named where it is proven below):
#   I3   fresh install of the fixed profile
#   F1   fixed -> normal  with a failing provisioning helper
#   F2   fixed -> offline with a failing provisioning helper
#   S5   fixed -> normal
#   S1   normal -> offline
#   F3   offline -> fixed with a failing post-install gate
#   S4   offline -> fixed
#   S6   fixed -> offline
#   U2   uninstall the offline profile
#   I1   fresh install of the normal profile
#   F3b  normal -> fixed with a failing post-install gate
#   S3   normal -> fixed
#   U3   uninstall the fixed profile
#   I2   fresh install of the offline profile
#   S2   offline -> normal
#   U1   uninstall the normal profile
#   F4   is not a step: EVERY failure row asserts the marker still equals
#        the SOURCE profile, because the marker is the commit point
#
# The failing post-install gate is run from BOTH Evergreen sources (F3
# from offline, F3b from normal) because that is the row the fixed
# profile's [Files] order was reordered for: the claim is that a failed
# Evergreen -> fixed switch leaves the SOURCE install byte-identical,
# and a claim about "Evergreen" proven from one source only would be
# half a proof.
#
# The chain order is not arbitrary. Every fresh install (I1/I2/I3) must
# follow an uninstall, every uninstall must follow an install of THAT
# profile, and the ~690 MB fixed profile is installed the minimum three
# times the rows require (I3, S4, S3). Cheap rows ride between expensive
# ones so nothing is installed twice for the same reason.
#
# WHAT THIS GATE NEVER DOES: it never provisions, installs, repairs or
# uninstalls the machine's shared WebView2 Evergreen runtime, and it
# never deletes the shared WebView2 user-data folder. Both are proven,
# not merely intended - the Evergreen detector's AVAILABILITY (status +
# usable) is sampled before and after the whole chain and must be
# identical, and a sentinel written into the user-data folder must
# survive all three uninstalls. The runtime's VERSION deliberately is
# NOT compared: Microsoft auto-updates it on its own schedule, and this
# chain runs long enough for that to happen.
#
# Hosted-session policy (the ratified run_cap6_smoke.ps1 rule): a usable
# runtime does not guarantee a desktop session, so `webview_create
# (returned nil` records a SKIP for the 42 half of a row and never a
# defect. The mode half is NOT skippable and never is: which BINARY is
# installed is proven by the fixed-mode marker the app prints BEFORE
# webview_create, so every row still proves its mode on a headless host.
#
# PRECONDITION: a machine whose WebView2 Evergreen runtime is already
# usable. This gate is the INTEGRATION matrix, not a provisioning gate -
# provisioning is owned by the CAP-6b1/6b2 clean-machine gates, which
# carry the 900 s helper bound plus an extraction margin precisely
# because they DO provision. Phase 0 therefore observes the detector and
# refuses to run on a runtime-less host rather than silently turning
# into a provisioning gate with the wrong bounds. With that assertion in
# place no setup in this chain can execute a Microsoft installer, so the
# Evergreen install bound below is the CAP-6b1 gate-2 value (300 s) for
# exactly the same operation, not the clean-machine value.
#
# BOUNDED-WAIT BUDGET - the honest arithmetic, polls included. Every
# number below is a CEILING that only fires on a hang; the measured
# wall time of a healthy full run on the development host is ~3 minutes.
#
#   phase-0 recovery uninstall     300 s exec + 120 s poll =  7.0 min
#   6 Evergreen installs                     6 x 300 s     = 30.0 min
#   2 Evergreen abort probes                 2 x 120 s     =  4.0 min
#   3 fixed installs                         3 x 420 s     = 21.0 min
#   2 fixed abort probes                     2 x 420 s     = 14.0 min
#   U3 fixed uninstall             300 s exec + 210 s poll =  8.5 min
#   U1 + U2 uninstalls        2 x (120 s exec + 210 s poll) = 11.0 min
#   5 fixed app runs               5 x (24 s poll + 60 s)  =  7.0 min
#   8 Evergreen app runs                     8 x  60 s     =  8.0 min
#   4 helper probes                          4 x  45 s     =  3.0 min
#                                                            --------
#                                                            113.5 min
#
# The declared CI step budget is 115 minutes: it exceeds this sum, which
# is the house rule. Note what the sum is NOT - it is not a prediction.
# Reaching it would require every bounded wait in the chain to hit its
# ceiling simultaneously, which means a hung machine, which is exactly
# when a step budget should fire.
#
# Usage: pwsh -File test/cap6b4/run_profile_matrix.ps1

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Push-Location $RepoRoot
try {
    foreach ($pre in 'build/cap6b4/switchfacts.psd1') {
        if (-not (Test-Path $pre)) {
            throw ("missing precondition: $pre -- run " +
                'test/cap6b4/build_switch_probes.ps1 first')
        }
    }
    $facts = Import-PowerShellDataFile (Resolve-Path build/cap6b4/switchfacts.psd1).Path
    foreach ($k in 'NormalSetup', 'OfflineSetup', 'FixedSetup', 'NormalAbortProbe',
        'OfflineAbortProbe', 'FixedAbortProbe', 'FixedHelper', 'RuntimeDir',
        'TreeName', 'FixedVersion') {
        if (-not $facts[$k]) { throw "switchfacts.psd1 carries no $k" }
        if (($k -ne 'TreeName') -and ($k -ne 'FixedVersion') -and
            (-not (Test-Path -LiteralPath $facts[$k]))) {
            throw "switchfacts.psd1 points $k at a missing path: $($facts[$k])"
        }
    }

    $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\PWebRelease'
    # per-user (PrivilegesRequired=lowest) Inno uninstall key for AppId
    # {7C3E9A1B-...} - the literal AppId from the shared identity include
    # tools/setup/pwebappsetup.issi (cross-checked by
    # test/cap6b1/check_cap6b1_contracts.ps1)
    $UninstKey = ('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
        '{7C3E9A1B-5D24-4F68-A0C9-2B8E6D4F1A57}_is1')
    $UninstRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    $UninstLeaf = '{7C3E9A1B-5D24-4F68-A0C9-2B8E6D4F1A57}_is1'
    # THE PROFILE MARKER - key path, value name and the three ratified
    # profile names, all cross-checked against their single authoring
    # source by test/cap6b4/check_cap6b4_contracts.ps1
    $MarkerKey = 'HKCU:\Software\PWeb\PWebRelease'
    $MarkerParent = 'HKCU:\Software\PWeb'
    $MarkerValue = 'Profile'
    $ProfileNormal = 'normal'
    $ProfileOffline = 'offline'
    $ProfileFixed = 'fixed-runtime'
    # the installed runtime subdirectory and its intermediate parent
    # (single-sourced as PWEB_RUNTIME_SUBDIR / PWEB_RUNTIME_PARENT in
    # tools/setup/pwebappsetup.issi; this script is a registered consumer
    # of both literals, so a rename there breaks the contract gate rather
    # than silently voiding the assertions below)
    $InstalledRuntime = Join-Path $InstallDir 'runtime\webview2'
    $InstalledRuntimeParent = Join-Path $InstallDir 'runtime'
    $InstalledTree = Join-Path $InstalledRuntime $facts.TreeName
    # the shared WebView2 user-data folder: the default derived from the
    # executable name. SHARED across profiles, PRESERVED by uninstall.
    $UserData = Join-Path $env:APPDATA 'releaseapp.exe'
    $Sentinel = Join-Path $UserData 'pweb-cap6b4-userdata-sentinel.txt'
    $Marker42 = 'releaseapp: app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS'
    $LogDir = Join-Path $RepoRoot 'build/cap6b4/matrix'
    New-Item -ItemType Directory -Force $LogDir | Out-Null

    $script:Skips = @()
    $script:SentinelWritten = $false
    $script:CimUsable = $false

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

    # --- the observations every row is written in terms of ------------------
    function Get-ProfileMarker {
        if (-not (Test-Path $MarkerKey)) { return $null }
        $p = Get-ItemProperty -Path $MarkerKey -Name $MarkerValue -ErrorAction SilentlyContinue
        if ($null -eq $p) { return $null }
        [string]$p.$MarkerValue
    }
    function Assert-Marker([string]$Expected, [string]$Row) {
        $seen = Get-ProfileMarker
        if ($null -eq $seen) {
            throw "${Row}: the profile marker is ABSENT; it must read '$Expected'"
        }
        if ($seen -cne $Expected) {
            throw "${Row}: the profile marker reads '$seen'; it must read '$Expected'"
        }
    }
    function Get-TripleHashes {
        $h = [ordered]@{}
        foreach ($f in 'releaseapp.exe', 'app.pwb', 'webview.dll') {
            $p = Join-Path $InstallDir $f
            if (-not (Test-Path -LiteralPath $p)) { throw "installed triple member missing: $f" }
            $h[$f] = (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLowerInvariant()
        }
        $h
    }
    function Assert-TripleUnchanged($Before, [string]$Row) {
        $after = Get-TripleHashes
        foreach ($f in $Before.Keys) {
            if ($after[$f] -cne $Before[$f]) {
                throw ("${Row}: the SOURCE install's $f changed across a FAILED " +
                    "switch ($($Before[$f]) -> $($after[$f])) - a failed switch " +
                    'must leave the source install byte-identical')
            }
        }
    }
    function Get-TreeStats {
        if (-not (Test-Path -LiteralPath $InstalledRuntime)) { return $null }
        $files = @(Get-ChildItem $InstalledRuntime -Recurse -File -Force)
        [pscustomobject]@{
            Files = $files.Count
            Bytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
        }
    }
    # DIRECTORY-level, not file-level. An empty leftover directory is
    # exactly the orphan class the reclaim exists to kill, and a
    # -Recurse -File enumeration can never see one.
    function Assert-NoTree([string]$Row) {
        if (Test-Path -LiteralPath $InstalledRuntime) {
            $left = @(Get-ChildItem $InstalledRuntime -Recurse -File -Force -ErrorAction SilentlyContinue)
            throw ("${Row}: the bundled runtime tree is still present " +
                "($($left.Count) file(s) under $InstalledRuntime) - the " +
                '[InstallDelete] reclaim did not run, or the install left an orphan')
        }
        # the INTERMEDIATE directory too: the Evergreen profiles never
        # recorded {app}\runtime, so nothing but the dirifempty reclaim
        # can ever remove it, and nothing but this assertion can see it
        if (Test-Path -LiteralPath $InstalledRuntimeParent) {
            throw ("${Row}: the intermediate directory $InstalledRuntimeParent " +
                'survived - the dirifempty reclaim did not run, and no uninstall ' +
                'will ever remove a directory this profile never recorded')
        }
    }
    function Assert-Tree($Expected, [string]$Row) {
        $t = Get-TreeStats
        if ($null -eq $t) { throw "${Row}: the bundled runtime tree is ABSENT" }
        if (($t.Files -ne $Expected.Files) -or ($t.Bytes -ne $Expected.Bytes)) {
            throw ("${Row}: the runtime tree is $($t.Files) file(s)/$($t.Bytes) " +
                "byte(s); expected $($Expected.Files)/$($Expected.Bytes)")
        }
    }
    # the exact installed layout, BY RELATIVE PATH (so unexpected nesting
    # fails, not just an unexpected basename), byte-exact case-sensitive
    $StagedRuntimeLen = ((Resolve-Path $facts.RuntimeDir).Path.TrimEnd('\') + '\').Length
    $ExpectedRuntimeRel = @(Get-ChildItem $facts.RuntimeDir -Recurse -File -Force |
        ForEach-Object { 'runtime\webview2\' + $_.FullName.Substring($StagedRuntimeLen) })
    $EvergreenLayout = @('app.pwb', 'releaseapp.exe', 'unins000.dat',
        'unins000.exe', 'webview.dll') | Sort-Object
    $FixedLayout = @($EvergreenLayout + $ExpectedRuntimeRel) | Sort-Object
    function Assert-Layout([string[]]$Expected, [string]$Row) {
        if (-not (Test-Path $InstallDir)) { throw "${Row}: install dir missing: $InstallDir" }
        $rootLen = (Resolve-Path $InstallDir).Path.Length + 1
        $files = @(Get-ChildItem $InstallDir -Recurse -File -Force |
            ForEach-Object { $_.FullName.Substring($rootLen) } | Sort-Object)
        if (($files -join "`n") -cne ($Expected -join "`n")) {
            $missing = @($Expected | Where-Object { $files -cnotcontains $_ })
            $extra = @($files | Where-Object { $Expected -cnotcontains $_ })
            throw ("${Row}: installed layout is not the exact relative-path set: " +
                "$($missing.Count) missing [$(($missing | Select-Object -First 5) -join ', ')], " +
                "$($extra.Count) unexpected [$(($extra | Select-Object -First 5) -join ', ')]")
        }
    }
    # ONE product means ONE uninstall registration, however many switches
    # ran: a second Inno uninstaller (unins001) or a second registry key
    # would mean two applications wearing one name
    function Assert-SingleRegistration([string]$Row) {
        if (-not (Test-Path $UninstKey)) {
            throw "${Row}: the per-user uninstall registration is missing: $UninstKey"
        }
        $keys = @(Get-ChildItem $UninstRoot -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like '*7C3E9A1B-5D24-4F68-A0C9-2B8E6D4F1A57*' })
        if ($keys.Count -ne 1) {
            throw ("${Row}: $($keys.Count) uninstall registrations exist for the " +
                'shared AppId; exactly one is ratified')
        }
        if ($keys[0].PSChildName -cne $UninstLeaf) {
            throw "${Row}: the uninstall registration is '$($keys[0].PSChildName)', expected '$UninstLeaf'"
        }
        $unins = @(Get-ChildItem $InstallDir -Filter 'unins*.exe' -File -ErrorAction SilentlyContinue)
        if ($unins.Count -ne 1) {
            throw ("${Row}: $($unins.Count) uninstaller executables in {app}; a " +
                'second one means a second registration')
        }
    }

    # --- running a setup, bounded and logged --------------------------------
    function Invoke-Setup {
        param([string]$Exe, [int]$TimeoutMs, [string]$Row, [switch]$ExpectFailure,
            [switch]$ExpectRollback, [switch]$ExpectNoFileOps)
        $log = Join-Path $LogDir "$Row.log"
        if (Test-Path $log) { Remove-Item -Force $log }
        $r = Invoke-Bounded $Exe @('/VERYSILENT', '/SUPPRESSMSGBOXES',
            '/NORESTART', '/SP-', "/LOG=$log") $TimeoutMs "$Row setup"
        if (-not (Test-Path $log)) { throw "${Row}: setup produced no log" }
        $text = Get-Content $log -Raw
        if ($ExpectFailure) {
            if ($r.Code -eq 0) {
                throw "${Row}: the setup exited 0; it had to fail closed"
            }
            # A nonzero exit alone is not the ratified property. WHICH
            # mechanism produced it is: these rows exist to prove Inno's
            # OWN rollback (the CAP-6b3 gate-10 assertion), so a future
            # change to a hand-rolled cleanup - the thing CAP-6b3
            # measured to be harmful - could not pass by exiting nonzero.
            if ($ExpectRollback) {
                foreach ($proof in 'Rolling back changes',
                                   'Uninstallation process succeeded') {
                    if ($text -notmatch [regex]::Escape($proof)) {
                        throw ("${Row}: the log does not prove INNO'S OWN rollback " +
                            "ran ('$proof' missing) - a nonzero exit from some " +
                            'other mechanism is not this row')
                    }
                }
            }
            # and the provisioning refusals must abort BEFORE the install
            # phase opens at all - "nonzero before any file op" is the
            # row's actual claim, and this is the log line that says so
            if ($ExpectNoFileOps) {
                if ($text -match 'Starting the installation process') {
                    throw ("${Row}: the setup entered its installation phase before " +
                        'aborting - the refusal must happen in PrepareToInstall, ' +
                        'with zero file operations')
                }
                if ($text -match 'Rolling back changes') {
                    throw ("${Row}: the setup rolled back, so it had something to " +
                        'roll back - this row must refuse before any file op')
                }
            }
        }
        elseif ($r.Code -ne 0) {
            Get-Content $log | Select-Object -Last 40 | Write-Host
            throw "${Row}: setup exited $($r.Code)"
        }
        # NOTHING this repository ships may uninstall or repair the shared
        # Evergreen runtime - assert it against every setup log we produce.
        # (The needles are concatenated so this file cannot literally match
        # its own source in the CAP-6b4 no-Evergreen-uninstall sweep - the
        # ratified ci.yml floating-ref-guard idiom.)
        foreach ($banned in ('MicrosoftEdge' + 'Update'), ('--unin' + 'stall'),
                            ('msi' + 'exec')) {
            if ($text -match [regex]::Escape($banned)) {
                throw ("${Row}: the setup log names '$banned' - the shared " +
                    'Evergreen runtime is machine state this product does not own')
            }
        }
        [pscustomobject]@{ Code = $r.Code; Log = $log; Text = $text }
    }

    # --- running the installed app ------------------------------------------
    # ExpectFixed decides the MODE assertion, which is never skippable: the
    # fixed-mode binary announces its selection BEFORE webview_create, so
    # a headless host still proves WHICH binary got installed.
    function Test-InstalledApp {
        param([string]$Row, [switch]$ExpectFixed)
        $exe = Join-Path $InstallDir 'releaseapp.exe'
        if (-not (Test-Path -LiteralPath $exe)) { throw "${Row}: installed app missing: $exe" }
        $env:PWEB_SMOKE_AUTOCLOSE_MS = '5000'
        $seen = @{}
        $text = ''
        $code = -1
        if ($ExpectFixed) {
            # the browser-image half of the ratified identity proof: watch,
            # from the OUTSIDE, which msedgewebview2.exe image our own PID
            # spawned - it must lie INSIDE the bundled tree
            $so = Join-Path $LogDir "$Row.smoke.log"
            $se = Join-Path $LogDir "$Row.smoke.err.log"
            foreach ($stale in $so, $se) { if (Test-Path $stale) { Remove-Item -Force $stale } }
            $p = Start-Process -FilePath $exe `
                -WorkingDirectory ([System.IO.Path]::GetTempPath()) `
                -RedirectStandardOutput $so -RedirectStandardError $se `
                -PassThru -WindowStyle Minimized
            # the poll is bounded at 60 x 400 ms = 24 s and the wait that
            # follows at 60 s, so this whole leg can never exceed the 90 s
            # this row is budgeted (the app auto-closes after 5 s)
            for ($i = 0; $i -lt 60; $i++) {
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
            if (-not $p.WaitForExit(60000)) {
                $p.Kill($true)
                throw "${Row}: the installed app did not exit within 60s and was killed"
            }
            $code = $p.ExitCode
            $text = ((Get-Content $so -Raw -ErrorAction SilentlyContinue) +
                (Get-Content $se -Raw -ErrorAction SilentlyContinue))
        }
        else {
            $r = Invoke-Bounded $exe @() 60000 "$Row installed app" `
                ([System.IO.Path]::GetTempPath())
            $code = $r.Code
            $text = $r.Out
        }

        # --- the MODE half: never skippable ---
        if ($ExpectFixed) {
            if ($text -notmatch 'FIXED RUNTIME SELECTED') {
                throw ("${Row}: the installed app did not select the bundled fixed " +
                    "runtime - the wrong binary is installed: $text")
            }
            if ($text -match 'FIXED RUNTIME REFUSED') {
                throw "${Row}: the installed app REFUSED its own bundled runtime: $text"
            }
            if ($text -match 'FIXED RUNTIME IDENTITY REFUSED') {
                throw ("${Row}: IDENTITY REFUSED - the WebView that opened is not " +
                    "the pinned runtime: $text")
            }
        }
        elseif ($text -match 'FIXED RUNTIME SELECTED') {
            throw ("${Row}: an EVERGREEN profile is installed but the app selected " +
                'a bundled fixed runtime - the switch installed the wrong binary')
        }

        # --- the 42 half: SKIP only on a genuinely absent desktop session ---
        if (($code -eq 0) -and ($text -match [regex]::Escape($Marker42))) {
            if ($ExpectFixed) {
                if ($text -cnotmatch [regex]::Escape(
                        "FIXED RUNTIME IDENTITY OK $($facts.FixedVersion)")) {
                    throw ("${Row}: the app did not OBSERVE the pinned runtime " +
                        "identity $($facts.FixedVersion): $text")
                }
                if ($seen.Count -eq 0) {
                    # "no child observed" is a defect ONLY if we could
                    # have observed one. If CIM itself is unavailable on
                    # this host the browser-image half was never
                    # measurable, and calling that a no-fallback
                    # violation would be a false accusation.
                    if ($script:CimUsable) {
                        throw ("${Row}: the app returned 42 but no msedgewebview2.exe " +
                            'child was ever observed, and CIM process enumeration ' +
                            'works on this host - the browser-image half of the ' +
                            'identity proof cannot be voided silently')
                    }
                    $script:Skips += ("${Row} (browser-image half: CIM process " +
                        'enumeration unavailable on this host)')
                }
                # directory-anchored: a sibling sharing the tree path as a
                # plain string prefix must not pass as "inside the tree"
                $treePrefix = $InstalledTree.TrimEnd('\') + '\'
                $outside = @($seen.Keys | Where-Object {
                    -not $_.StartsWith($treePrefix, [StringComparison]::OrdinalIgnoreCase) })
                if ($outside) {
                    throw ("${Row}: NO-FALLBACK BROKEN - the browser process ran " +
                        "from OUTSIDE the bundled tree: $($outside -join ', ')")
                }
            }
            return 'PASS'
        }
        if ($text -match 'webview_create \(returned nil') {
            # the ratified conditional hosted policy: a usable runtime does
            # not guarantee a desktop session; only that state records SKIP
            $script:Skips += "${Row} (42 half: no desktop session for webview_create)"
            return 'SKIP'
        }
        throw "${Row}: installed-app smoke failed (exit $code): $text"
    }

    # --- uninstall, and what must be gone afterwards ------------------------
    function Invoke-Uninstall {
        param([string]$Row, [int]$TimeoutMs)
        $unins = Join-Path $InstallDir 'unins000.exe'
        if (-not (Test-Path -LiteralPath $unins)) { throw "${Row}: uninstaller missing: $unins" }
        # the Inno uninstaller respawns a copy of itself and the original
        # process exits early: poll for the result, bounded
        $u = Invoke-Bounded $unins @('/VERYSILENT', '/SUPPRESSMSGBOXES',
            '/NORESTART') $TimeoutMs "$Row uninstall"
        if ($u.Code -ne 0) { throw "${Row}: silent uninstall exited $($u.Code)" }
        # poll for {app} to DISAPPEAR, not merely to empty: an empty
        # leftover directory is not a clean uninstall, and a -File
        # enumeration would report one as success
        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        while (([DateTime]::UtcNow -lt $deadline) -and (Test-Path $InstallDir)) {
            Start-Sleep -Milliseconds 500
        }
        if (Test-Path $InstallDir) {
            $leftFiles = @(Get-ChildItem $InstallDir -Recurse -File -Force -ErrorAction SilentlyContinue |
                ForEach-Object Name)
            $leftDirs = @(Get-ChildItem $InstallDir -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                ForEach-Object FullName)
            throw ("${Row}: the install directory itself survived the uninstall " +
                "($InstallDir): $($leftFiles.Count) file(s) " +
                "[$(($leftFiles | Select-Object -First 5) -join ', ')], " +
                "$($leftDirs.Count) subdirectory(ies) " +
                "[$(($leftDirs | Select-Object -First 3) -join ', ')]")
        }
        # the registration and the marker go too (bounded polls: the
        # respawned uninstaller removes them near the very end)
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while (([DateTime]::UtcNow -lt $deadline) -and (Test-Path $UninstKey)) {
            Start-Sleep -Milliseconds 500
        }
        if (Test-Path $UninstKey) {
            throw "${Row}: uninstall left the HKCU uninstall registry key: $UninstKey"
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (([DateTime]::UtcNow -lt $deadline) -and ($null -ne (Get-ProfileMarker))) {
            Start-Sleep -Milliseconds 500
        }
        $left = Get-ProfileMarker
        if ($null -ne $left) {
            throw "${Row}: uninstall left the profile marker behind, reading '$left'"
        }
        if (Test-Path $MarkerParent) {
            $sub = @(Get-ChildItem $MarkerParent -ErrorAction SilentlyContinue)
            $val = @((Get-Item $MarkerParent).GetValueNames())
            if (($sub.Count -eq 0) -and ($val.Count -eq 0)) {
                throw ("${Row}: the marker's parent key $MarkerParent survived " +
                    'EMPTY - uninsdeletekeyifempty did not run')
            }
        }
        # AND THE USER DATA SURVIVES. This is the row's other half: a
        # profile switch must never destroy application state.
        Assert-UserDataPreserved $Row
    }
    function Assert-UserDataPreserved([string]$Row) {
        if (-not (Test-Path -LiteralPath $Sentinel)) {
            throw ("${Row}: the shared WebView2 user-data folder lost its sentinel " +
                "($Sentinel) - uninstall must PRESERVE user data, never delete it")
        }
        $now = (Get-FileHash -Algorithm SHA256 -LiteralPath $Sentinel).Hash.ToLowerInvariant()
        if ($now -cne $script:SentinelSha) {
            throw "${Row}: the user-data sentinel was rewritten across an uninstall"
        }
    }

    # =======================================================================
    # PHASE 0 - a clean machine, a user-data sentinel, an Evergreen baseline
    # =======================================================================
    if (Test-Path (Join-Path $InstallDir 'unins000.exe')) {
        Write-Host 'phase 0: an earlier install is present - removing it through its own uninstaller'
        $u = Invoke-Bounded (Join-Path $InstallDir 'unins000.exe') @('/VERYSILENT',
            '/SUPPRESSMSGBOXES', '/NORESTART') 300000 'phase 0 uninstall'
        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        while (([DateTime]::UtcNow -lt $deadline) -and (Test-Path $InstallDir)) {
            Start-Sleep -Milliseconds 500
        }
    }
    if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
    # stale HARNESS state from an aborted earlier run is cleared here (and
    # only here): a leftover marker or registration would fake a PASS.
    # ONLY this product's own key is removed - HKCU\Software\PWeb is a
    # shared parent that a neighbouring PWeb product may own, and wiping
    # it would break the very uninsdeletekeyifempty invariant the shared
    # identity include advertises.
    if (Test-Path $UninstKey) { Remove-Item -Recurse -Force $UninstKey }
    if (Test-Path $MarkerKey) { Remove-Item -Recurse -Force $MarkerKey }
    if ($null -ne (Get-ProfileMarker)) { throw 'phase 0: the profile marker survived the clean-up' }

    # the user-data sentinel. The folder is the WebView2 default derived
    # from the executable name and is SHARED by all three modes; we only
    # ever ADD one file to it and never remove the folder.
    New-Item -ItemType Directory -Force $UserData | Out-Null
    Set-Content -LiteralPath $Sentinel -Encoding utf8 -Value @(
        'CAP-6b4 user-data preservation sentinel.',
        'This folder is the SHARED WebView2 user-data folder for releaseapp.exe.',
        'No PWeb uninstaller may ever delete it.')
    $script:SentinelSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $Sentinel).Hash.ToLowerInvariant()
    $script:SentinelWritten = $true

    # CIM availability, measured ONCE against a process we know exists.
    # Without this, "no msedgewebview2.exe child was observed" would be
    # indistinguishable from "process enumeration does not work here",
    # and the first of those is a no-fallback defect while the second is
    # simply an unmeasurable half of the proof.
    $script:CimUsable = $null -ne (Get-CimInstance Win32_Process `
        -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue)

    # the Evergreen baseline: this whole chain must leave it IDENTICAL
    $d = Invoke-Bounded $facts.FixedHelper @('--detect') 45000 'Evergreen baseline detect'
    if ($d.Out -notmatch '(?m)^(WV2FIXED_DETECT [^\r\n]*)') {
        throw "phase 0: the Evergreen detector produced no structured verdict: $($d.Out)"
    }
    $EvergreenBefore = $Matches[1].Trim()
    # THE PRECONDITION. This is the integration matrix, not a provisioning
    # gate: every Evergreen install below is bounded for the AlreadyUsable
    # path, and the 900 s helper bound plus extraction margin belongs to
    # the CAP-6b1/6b2 clean-machine gates that actually provision. Rather
    # than silently becoming a provisioning gate with the wrong bounds,
    # refuse - loudly, because this chain is the CAP-13 acceptance
    # evidence and a silent skip of it would be worse than a failure.
    if ($EvergreenBefore -notmatch 'usable=true') {
        if ($env:GITHUB_ACTIONS) {
            throw ('phase 0: the hosted runner reports no usable WebView2 Evergreen ' +
                'runtime - hosted Windows runners are documented runtime-present, ' +
                "so the CAP-6b4 matrix cannot run; runner image changed? ($EvergreenBefore)")
        }
        throw ('phase 0: this host has no usable WebView2 Evergreen runtime ' +
            "($EvergreenBefore). The CAP-6b4 matrix is the INTEGRATION gate and " +
            'deliberately never provisions: install a runtime first, or run the ' +
            'ratified provisioning proofs (test/cap6b1/run_clean_machine_gate.ps1, ' +
            'test/cap6b2/run_offline_clean_machine_gate.ps1) which own that path')
    }
    Write-Host ("phase 0 OK (clean machine, user-data sentinel written, CIM " +
        "enumeration usable=$($script:CimUsable), Evergreen baseline: $EvergreenBefore)")

    # the authoritative expectation is the STAGED tree the build embedded
    # (the pinned Fixed Runtime tree plus the bundled pinned-SDK loader)
    $stagedFiles = @(Get-ChildItem $facts.RuntimeDir -Recurse -File -Force)
    $ExpectedTree = [pscustomobject]@{
        Files = $stagedFiles.Count
        Bytes = [long](($stagedFiles | Measure-Object -Property Length -Sum).Sum)
    }

    # =======================================================================
    # I3 - fresh install of the fixed profile
    # =======================================================================
    [void](Invoke-Setup $facts.FixedSetup 420000 'I3')
    Assert-Marker $ProfileFixed 'I3'
    Assert-Tree $ExpectedTree 'I3'
    Assert-Layout $FixedLayout 'I3'
    Assert-SingleRegistration 'I3'
    $v = Test-InstalledApp 'I3' -ExpectFixed
    Write-Host "CAP-6b4 I3 $v (fresh fixed install: marker '$ProfileFixed', tree deployed, exact layout, one registration)"

    # =======================================================================
    # F1 - fixed -> normal, provisioning helper fails: nothing may move
    # =======================================================================
    $tripleBefore = Get-TripleHashes
    $treeBefore = Get-TreeStats
    $f1 = Invoke-Setup $facts.NormalAbortProbe 120000 'F1' -ExpectFailure -ExpectNoFileOps
    if ($f1.Text -notmatch 'WV2PROV_RESULT outcome=Failed step=verify_digest') {
        throw 'F1: the abort-probe log does not show the provisioning helper failure verdict'
    }
    if ($f1.Text -notmatch 'PWEB_WV2PROV exit=3') {
        throw 'F1: the abort-probe log does not show the helper nonzero exit'
    }
    Assert-TripleUnchanged $tripleBefore 'F1'
    $treeAfter = Get-TreeStats
    if (($null -eq $treeAfter) -or ($treeAfter.Files -ne $treeBefore.Files) -or
        ($treeAfter.Bytes -ne $treeBefore.Bytes)) {
        throw 'F1: the fixed runtime tree changed across a REFUSED switch'
    }
    Assert-Marker $ProfileFixed 'F1'          # F4: the marker is the SOURCE
    Assert-Layout $FixedLayout 'F1'
    Assert-SingleRegistration 'F1'
    $v = Test-InstalledApp 'F1' -ExpectFixed
    Write-Host "CAP-6b4 F1 $v (fixed -> normal REFUSED before any file op: install byte-identical, tree intact, marker still '$ProfileFixed')"

    # =======================================================================
    # F2 - fixed -> offline, provisioning helper fails: nothing may move
    # =======================================================================
    $tripleBefore = Get-TripleHashes
    $treeBefore = Get-TreeStats
    $f2 = Invoke-Setup $facts.OfflineAbortProbe 120000 'F2' -ExpectFailure -ExpectNoFileOps
    if ($f2.Text -notmatch 'WV2PROV_RESULT outcome=Failed step=verify_digest') {
        throw 'F2: the abort-probe log does not show the provisioning helper failure verdict'
    }
    if ($f2.Text -notmatch 'PWEB_WV2PROV exit=3') {
        throw 'F2: the abort-probe log does not show the helper nonzero exit'
    }
    Assert-TripleUnchanged $tripleBefore 'F2'
    $treeAfter = Get-TreeStats
    if (($null -eq $treeAfter) -or ($treeAfter.Files -ne $treeBefore.Files) -or
        ($treeAfter.Bytes -ne $treeBefore.Bytes)) {
        throw 'F2: the fixed runtime tree changed across a REFUSED switch'
    }
    Assert-Marker $ProfileFixed 'F2'          # F4: the marker is the SOURCE
    Assert-Layout $FixedLayout 'F2'
    Assert-SingleRegistration 'F2'
    $v = Test-InstalledApp 'F2' -ExpectFixed
    Write-Host "CAP-6b4 F2 $v (fixed -> offline REFUSED before any file op: install byte-identical, tree intact, marker still '$ProfileFixed')"

    # =======================================================================
    # S5 - fixed -> normal: Evergreen proven FIRST, then the tree is reclaimed
    # =======================================================================
    $s5 = Invoke-Setup $facts.NormalSetup 300000 'S5'
    if ($s5.Text -notmatch 'PWEB_WV2PROV exit=0') {
        throw 'S5: the setup log does not show the Evergreen provisioning gate passing FIRST'
    }
    if ($s5.Text -notmatch 'WV2PROV_RESULT outcome=(AlreadyUsable|Provisioned)') {
        throw 'S5: the setup log carries no usable-runtime verdict'
    }
    Assert-NoTree 'S5'
    Assert-Marker $ProfileNormal 'S5'
    Assert-Layout $EvergreenLayout 'S5'
    Assert-SingleRegistration 'S5'
    $v = Test-InstalledApp 'S5'
    Write-Host "CAP-6b4 S5 $v (fixed -> normal: Evergreen proven first, ~690 MB tree RECLAIMED, marker '$ProfileNormal', Evergreen-mode app)"

    # =======================================================================
    # S1 - normal -> offline
    # =======================================================================
    [void](Invoke-Setup $facts.OfflineSetup 300000 'S1')
    Assert-NoTree 'S1'
    Assert-Marker $ProfileOffline 'S1'
    Assert-Layout $EvergreenLayout 'S1'
    Assert-SingleRegistration 'S1'
    $v = Test-InstalledApp 'S1'
    Write-Host "CAP-6b4 S1 $v (normal -> offline: marker flips to '$ProfileOffline', no tree ever, one registration)"

    # =======================================================================
    # F3 - offline -> fixed, post-install gate fails: Inno's OWN rollback
    # =======================================================================
    $tripleBefore = Get-TripleHashes
    $f3 = Invoke-Setup $facts.FixedAbortProbe 420000 'F3' -ExpectFailure -ExpectRollback
    if ($f3.Text -notmatch 'WV2FIXED_RESULT outcome=Failed step=signers') {
        throw 'F3: the abort-probe log does not show the post-install helper failure verdict'
    }
    if ($f3.Text -notmatch 'PWEB_WV2FIXED REFUSED') {
        throw 'F3: the abort-probe log does not show the gate refusing with a reason'
    }
    if ($f3.Text -match 'PWEB_WV2FIXED verdict written') {
        throw 'F3: a failing gate still wrote its verdict file'
    }
    # (the INNO'S-OWN-rollback proof is asserted by Invoke-Setup
    # -ExpectRollback above, so no row can lose it by omission)
    Assert-NoTree 'F3'
    Assert-TripleUnchanged $tripleBefore 'F3'
    Assert-Marker $ProfileOffline 'F3'        # F4: the marker is the SOURCE
    Assert-Layout $EvergreenLayout 'F3'
    Assert-SingleRegistration 'F3'
    $v = Test-InstalledApp 'F3'
    Write-Host "CAP-6b4 F3 $v (offline -> fixed REFUSED: Inno's own rollback, NO tree, NO half-install, source triple byte-identical, marker still '$ProfileOffline')"

    # =======================================================================
    # S4 - offline -> fixed
    # =======================================================================
    [void](Invoke-Setup $facts.FixedSetup 420000 'S4')
    Assert-Marker $ProfileFixed 'S4'
    Assert-Tree $ExpectedTree 'S4'
    Assert-Layout $FixedLayout 'S4'
    Assert-SingleRegistration 'S4'
    # the DEPLOYED tree carries the ratified AppContainer grant, by SID
    $a = Invoke-Bounded $facts.FixedHelper @('--acl-verify', $InstalledTree) 45000 'S4 ACL verify'
    if (($a.Code -ne 0) -or ($a.Out -notmatch 'WV2FIXED_RESULT outcome=Ok')) {
        throw "S4: the switched-in tree failed ACL verification (exit $($a.Code)): $($a.Out)"
    }
    foreach ($sid in 'S-1-15-2-1', 'S-1-15-2-2') {
        if ($a.Out -cnotmatch [regex]::Escape($sid)) {
            throw "S4: the ACL verdict does not name $sid"
        }
    }
    $v = Test-InstalledApp 'S4' -ExpectFixed
    Write-Host "CAP-6b4 S4 $v (offline -> fixed: tree installed and verified by SID, marker '$ProfileFixed', observed pin $($facts.FixedVersion))"

    # =======================================================================
    # S6 - fixed -> offline
    # =======================================================================
    $s6 = Invoke-Setup $facts.OfflineSetup 300000 'S6'
    if ($s6.Text -notmatch 'PWEB_WV2PROV exit=0') {
        throw 'S6: the setup log does not show the Evergreen provisioning gate passing FIRST'
    }
    Assert-NoTree 'S6'
    Assert-Marker $ProfileOffline 'S6'
    Assert-Layout $EvergreenLayout 'S6'
    Assert-SingleRegistration 'S6'
    $v = Test-InstalledApp 'S6'
    Write-Host "CAP-6b4 S6 $v (fixed -> offline: Evergreen proven first, tree RECLAIMED, marker '$ProfileOffline')"

    # =======================================================================
    # U2 - uninstall the offline profile
    # =======================================================================
    Invoke-Uninstall 'U2' 120000
    Write-Host 'CAP-6b4 U2 PASS (offline uninstall: {app}, registration and marker gone; user data PRESERVED)'

    # =======================================================================
    # I1 - fresh install of the normal profile
    # =======================================================================
    [void](Invoke-Setup $facts.NormalSetup 300000 'I1')
    Assert-Marker $ProfileNormal 'I1'
    Assert-NoTree 'I1'
    Assert-Layout $EvergreenLayout 'I1'
    Assert-SingleRegistration 'I1'
    $v = Test-InstalledApp 'I1'
    Write-Host "CAP-6b4 I1 $v (fresh normal install: marker '$ProfileNormal', exact layout, no tree)"

    # =======================================================================
    # F3b - normal -> fixed, post-install gate fails: Inno's OWN rollback
    # =======================================================================
    # The SECOND source of the same failure. F3 proved it from an offline
    # install; the fixed profile's [Files] reorder is justified in terms
    # of "a failed Evergreen -> fixed switch", and that claim is only
    # half proven from one Evergreen source. The probe already exists, so
    # this row costs one more run and closes the other half.
    $tripleBefore = Get-TripleHashes
    $f3b = Invoke-Setup $facts.FixedAbortProbe 420000 'F3b' -ExpectFailure -ExpectRollback
    if ($f3b.Text -notmatch 'WV2FIXED_RESULT outcome=Failed step=signers') {
        throw 'F3b: the abort-probe log does not show the post-install helper failure verdict'
    }
    if ($f3b.Text -notmatch 'PWEB_WV2FIXED REFUSED') {
        throw 'F3b: the abort-probe log does not show the gate refusing with a reason'
    }
    if ($f3b.Text -match 'PWEB_WV2FIXED verdict written') {
        throw 'F3b: a failing gate still wrote its verdict file'
    }
    Assert-NoTree 'F3b'
    Assert-TripleUnchanged $tripleBefore 'F3b'
    Assert-Marker $ProfileNormal 'F3b'        # F4: the marker is the SOURCE
    Assert-Layout $EvergreenLayout 'F3b'
    Assert-SingleRegistration 'F3b'
    $v = Test-InstalledApp 'F3b'
    Write-Host "CAP-6b4 F3b $v (normal -> fixed REFUSED: Inno's own rollback, NO tree, NO half-install, source triple byte-identical, marker still '$ProfileNormal')"

    # =======================================================================
    # S3 - normal -> fixed
    # =======================================================================
    [void](Invoke-Setup $facts.FixedSetup 420000 'S3')
    Assert-Marker $ProfileFixed 'S3'
    Assert-Tree $ExpectedTree 'S3'
    Assert-Layout $FixedLayout 'S3'
    Assert-SingleRegistration 'S3'
    $v = Test-InstalledApp 'S3' -ExpectFixed
    Write-Host "CAP-6b4 S3 $v (normal -> fixed: tree installed, marker '$ProfileFixed', observed pin $($facts.FixedVersion))"

    # =======================================================================
    # U3 - uninstall the fixed profile (the whole ~690 MB tree goes too)
    # =======================================================================
    Invoke-Uninstall 'U3' 300000
    Write-Host 'CAP-6b4 U3 PASS (fixed uninstall: {app}, the whole runtime tree, registration and marker gone; user data PRESERVED)'

    # =======================================================================
    # I2 - fresh install of the offline profile
    # =======================================================================
    [void](Invoke-Setup $facts.OfflineSetup 300000 'I2')
    Assert-Marker $ProfileOffline 'I2'
    Assert-NoTree 'I2'
    Assert-Layout $EvergreenLayout 'I2'
    Assert-SingleRegistration 'I2'
    $v = Test-InstalledApp 'I2'
    Write-Host "CAP-6b4 I2 $v (fresh offline install: marker '$ProfileOffline', exact layout, no tree)"

    # =======================================================================
    # S2 - offline -> normal
    # =======================================================================
    [void](Invoke-Setup $facts.NormalSetup 300000 'S2')
    Assert-NoTree 'S2'
    Assert-Marker $ProfileNormal 'S2'
    Assert-Layout $EvergreenLayout 'S2'
    Assert-SingleRegistration 'S2'
    $v = Test-InstalledApp 'S2'
    Write-Host "CAP-6b4 S2 $v (offline -> normal: marker flips back to '$ProfileNormal', still one registration)"

    # =======================================================================
    # U1 - uninstall the normal profile
    # =======================================================================
    Invoke-Uninstall 'U1' 120000
    Write-Host 'CAP-6b4 U1 PASS (normal uninstall: {app}, registration and marker gone; user data PRESERVED)'

    # =======================================================================
    # THE SHARED STATE THIS CHAIN MAY NEVER HAVE TOUCHED
    # =======================================================================
    $d = Invoke-Bounded $facts.FixedHelper @('--detect') 45000 'Evergreen final detect'
    if ($d.Out -notmatch '(?m)^(WV2FIXED_DETECT [^\r\n]*)') {
        throw "the Evergreen detector produced no structured verdict at the end: $($d.Out)"
    }
    $EvergreenAfter = $Matches[1].Trim()
    # THE INVARIANT IS THE STATUS, NOT THE VERSION STRING. Microsoft's
    # Evergreen runtime auto-updates itself on its own schedule, and this
    # chain runs long enough for that to happen; comparing the raw
    # verdict would turn somebody else's background update into a false
    # accusation against this repository. What this repository must never
    # do is INSTALL, REPAIR or UNINSTALL it - i.e. flip its availability.
    function Get-DetectField([string]$Line, [string]$Key) {
        if ($Line -match "$Key=([^\s]+)") { return $Matches[1] }
        ''
    }
    $beforeUsable = Get-DetectField $EvergreenBefore 'usable'
    $afterUsable = Get-DetectField $EvergreenAfter 'usable'
    $beforeStatus = Get-DetectField $EvergreenBefore 'status'
    $afterStatus = Get-DetectField $EvergreenAfter 'status'
    if (($beforeUsable -cne $afterUsable) -or ($beforeStatus -cne $afterStatus)) {
        throw ("SHARED EVERGREEN RUNTIME CHANGED across the matrix: " +
            "status/usable went '$beforeStatus/$beforeUsable' -> " +
            "'$afterStatus/$afterUsable'. Nothing this repository ships may " +
            "install, repair or uninstall it.`n  before: $EvergreenBefore" +
            "`n  after:  $EvergreenAfter")
    }
    if ($EvergreenAfter -cne $EvergreenBefore) {
        # informational, never a failure: the version token moved without
        # the availability changing, which is Microsoft auto-updating its
        # own runtime underneath us
        Write-Host ("CAP-6b4 note: the Evergreen runtime VERSION changed during " +
            "the chain while its availability did not - Microsoft auto-update, " +
            "not this repository.`n  before: $EvergreenBefore`n  after:  $EvergreenAfter")
    }
    Assert-UserDataPreserved 'final'
    Write-Host ("CAP-6b4 shared-state PASS (Evergreen availability identical before " +
        "and after: status=$afterStatus usable=$afterUsable; user data preserved " +
        'through all three uninstalls)')

    if ($script:Skips.Count -gt 0) {
        Write-Host ''
        Write-Host "CAP-6b4 matrix SKIPS (hosted-session policy, never defects):"
        foreach ($s in $script:Skips) { Write-Host "  - $s" }
    }
    if ($env:GITHUB_STEP_SUMMARY) {
        $skipLine = 'no skips'
        if ($script:Skips.Count -gt 0) {
            $skipLine = "$($script:Skips.Count) 42-marker SKIP(s) (no desktop session)"
        }
        ("### CAP-6b4 profile matrix`nPASS - I1-I3, S1-S6, F1-F4, U1-U3 over the " +
         "three real setups: marker commit point, tree reclaim, fail-closed " +
         "switches with byte-identical source installs, Inno's own rollback, " +
         "user data preserved, shared Evergreen untouched ($skipLine)") |
            Out-File -Append $env:GITHUB_STEP_SUMMARY
    }
    Write-Host 'CAP6B4_MATRIX_PASS'
}
finally {
    # The machine is left as it was found on EVERY path, not just the
    # success one: a mid-chain throw used to strand our sentinel inside
    # the user's shared WebView2 folder and leave two environment
    # variables set in the caller's session - including the HOSTILE
    # browser-folder override, which would then perturb any later run.
    if ($script:SentinelWritten -and (Test-Path -LiteralPath $Sentinel)) {
        # our own file only; the shared folder is the user's, not ours
        Remove-Item -LiteralPath $Sentinel -Force -ErrorAction SilentlyContinue
    }
    foreach ($v in 'PWEB_SMOKE_AUTOCLOSE_MS', 'WEBVIEW2_BROWSER_EXECUTABLE_FOLDER') {
        Remove-Item -LiteralPath "Env:\$v" -ErrorAction SilentlyContinue
    }
    Pop-Location
}
