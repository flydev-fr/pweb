# CAP-10D1: the Windows-only packaging legs, dot-sourced by
# test/cap10d1/run_cap10d1_gates.ps1.
#
#   W5  a pinned input absent, and a pinned input whose digest drifted
#   W6  a compiler whose pin stamp is not the ratified one
#   W7  an identity value carrying a metacharacter
#   L1  the project-root ceiling, MEASURED on this runner
#   W1  the normal profile installed, launched and uninstalled for real
#   W4  two bundleIds side by side, and one project replacing itself
#
# THEY LIVE IN THEIR OWN FILE for one reason: they are the only legs that
# install software on the machine running them, and a reader auditing what
# this gate does to a runner should be able to read that half on its own.
#
# THE ORDER IS DELIBERATE. The four legs that need no artifact run first, so
# a build that produced none still yields their diagnostics; the two that
# install software run last, behind a guard whose early return therefore
# skips only them.
#
# It dot-sources test/cap10d0/psargs.ps1 itself rather than relying on its
# caller: the helper only defines a function, so sourcing it twice is free,
# and a file that calls Start-PWebProcess without it is exactly what
# check_cap10d0_contracts.ps1 refuses.
#
# It expects the caller to have defined: Row, Require, Bool, RunCli,
# SortOrdinal, InventoryOf, DistDirOf, $repoRoot, $work, $sdk, $target,
# $projA, $projB, $spaced, $cwd, $artifacts and $rows.

. (Join-Path $repoRoot 'test/cap10d0/psargs.ps1')
# the CAP-6b3 path-scoped drain, dot-sourced rather than reimplemented: a
# WebView2 host leaves browser processes holding the installed tree, and a
# gate that killed by NAME alone would kill a developer's own browser
. (Join-Path $repoRoot 'test/cap6b3/wv2procdrain.ps1')

function InvokeBounded([string]$Exe, [string[]]$Args2, [int]$TimeoutMs,
    [string]$What) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Exe
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($a in $Args2) { [void]$start.ArgumentList.Add($a) }
    $proc = [Diagnostics.Process]::Start($start)
    if ($null -eq $proc) { throw "failed to start $What" }
    try {
        $o = $proc.StandardOutput.ReadToEndAsync()
        $e = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            $proc.Kill($true)
            $proc.WaitForExit()
            throw "$What exceeded $TimeoutMs ms and was killed"
        }
        return [pscustomobject]@{
            Code = $proc.ExitCode
            Out = ($o.GetAwaiter().GetResult() + $e.GetAwaiter().GetResult())
        }
    } finally { $proc.Dispose() }
}

$silent = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-')

# the three identifiers the CAP-10D1 rules derive, restated here as the
# READER of them rather than as a second source: each is what a machine
# would have to carry if the derivation is what the contract says
function InstallDirFor([string]$BundleId) {
    $dot = $BundleId.LastIndexOf('.')
    return (Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') `
        $BundleId.Substring(0, $dot)) $BundleId.Substring($dot + 1))
}
function UninstallKeyFor([string]$BundleId) {
    return ('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
        $BundleId + '_is1')
}
function MarkerKeyFor([string]$BundleId) {
    return "HKCU:\Software\PWeb\Apps\$BundleId"
}
function UninstallIfPresent([string]$BundleId) {
    $dir = InstallDirFor $BundleId
    $unins = Join-Path $dir 'unins000.exe'
    if (Test-Path -LiteralPath $unins) {
        [void](InvokeBounded $unins $silent 300000 "uninstall $BundleId")
        Start-Sleep -Milliseconds 1500
    }
    if (Test-Path -LiteralPath $dir) {
        Assert-PWebProcessDrained -Root $dir -What 'installed application' `
            -Names @('msedgewebview2.exe', 'demopack.exe', 'altpack.exe')
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $dir
    }
}

# a machine carrying a previous run's install is not a clean one
UninstallIfPresent 'com.example.demopack'
UninstallIfPresent 'org.other.altpack'

# --- F1: the fixed profile's MAX_PATH arithmetic, RE-MEASURED --------------
# PWEB_PACK_FIXED_TREE_MAX_REL is a property of Microsoft's cabinet, not a
# number this repository chose, so it is re-measured here against the tree
# CAP-6b3 already expanded in this same job. A pin BELOW what the cabinet
# really holds would let a project root through that ISCC then refuses with
# an opaque Windows error after compressing 690 MB - which is exactly what
# this leg exists to make impossible.
$cap6b3Tree = Join-Path $repoRoot 'build/cap6b3/runtime'
if (Test-Path -LiteralPath $cap6b3Tree) {
    $deepest = 0
    foreach ($f in (Get-ChildItem -LiteralPath $cap6b3Tree -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($cap6b3Tree.Length + 1)
        if ($rel.Length -gt $deepest) { $deepest = $rel.Length }
    }
    Row 'fixed_tree_max_rel_measured' "$deepest"
    $pinned = 0
    $pinSrc = [System.IO.File]::ReadAllText(
        (Join-Path $repoRoot 'tools/pweb/pweb.cli.packpins.pas'))
    if ($pinSrc -match 'PWEB_PACK_FIXED_TREE_MAX_REL\s*=\s*(\d+)\s*;') {
        $pinned = [int]$Matches[1]
    }
    Row 'fixed_tree_max_rel_pinned' "$pinned"
    Require ($deepest -gt 0) 'F1: the CAP-6b3 runtime tree measured as empty'
    Require ($pinned -ge $deepest) `
        ("F1: PWEB_PACK_FIXED_TREE_MAX_REL is $pinned and the pinned " +
         "cabinet's deepest entry is $deepest -- a project root would be " +
         'accepted that ISCC then refuses')
} else {
    Row 'fixed_tree_max_rel_measured' 'unmeasured'
    Row 'fixed_tree_max_rel_pinned' 'unmeasured'
}

# --- W5: a pinned input absent, and one whose digest drifted ----------------
# the standalone installer is moved ASIDE rather than deleted: this gate
# borrows a 212 MB artifact and gives it back
$wv2Dir = Join-Path $sdk 'share/pweb/deps/webview2-runtime'
$standalone = Join-Path $wv2Dir 'MicrosoftEdgeWebView2RuntimeInstallerX64.exe'
$aside = "$standalone.aside"
$distOffline = DistDirOf $projA 'offline'
$offlineBefore = InventoryOf $distOffline
Move-Item -LiteralPath $standalone -Destination $aside -Force
try {
    $miss = RunCli @('build', '--project', $projA, '--profile', 'offline') $cwd 300000
    Row 'profile_missing_input_exit' "$($miss.Code)"
    Row 'profile_missing_input_cause' $(
        if ($miss.Err -match 'pack_input_missing') { 'pack_input_missing' }
        else { 'other' })
    Row 'profile_missing_input_names_script' (Bool (
        $miss.Err -match 'get-webview2-runtime\.ps1'))
    Require ($miss.Code -eq 4) `
        "W5: an absent pinned input exited $($miss.Code); the ratified refusal is 4"
    Require ($miss.Err -match 'pack_input_missing') `
        'W5: the refusal is not typed pack_input_missing'
    Require ($miss.Err -match 'get-webview2-runtime\.ps1') `
        'W5: the remediation does not name the provisioning script'
    Require ($miss.Err -match 'never downloads') `
        'W5: the remediation does not say the command never downloads'
    # THE PREFLIGHT REFUSED, so the pipeline never ran and the previously
    # committed offline artifacts are exactly as they were
    $offlineAfter = InventoryOf $distOffline
    Require ($offlineAfter.Text -ceq $offlineBefore.Text) `
        'W5: a refused preflight changed the committed artifacts'
    # a DRIFTED digest is a different refusal from an absent artifact
    [System.IO.File]::WriteAllBytes($standalone, [byte[]]@(1, 2, 3))
    $drift = RunCli @('build', '--project', $projA, '--profile', 'offline') $cwd 300000
    Row 'profile_drifted_input_exit' "$($drift.Code)"
    Row 'profile_drifted_input_cause' $(
        if ($drift.Err -match 'pack_input_digest') { 'pack_input_digest' }
        else { 'other' })
    Require ($drift.Code -eq 4) "W5: a drifted pinned input exited $($drift.Code)"
    Require ($drift.Err -match 'pack_input_digest') `
        'W5: a drifted input is not typed pack_input_digest'
    Remove-Item -Force -LiteralPath $standalone
} finally {
    Move-Item -LiteralPath $aside -Destination $standalone -Force
}

# --- W6: a compiler whose pin stamp is not the ratified one -----------------
$stamp = Join-Path $sdk 'share/pweb/deps/innosetup/.pweb-pin'
$stampWas = [System.IO.File]::ReadAllText($stamp)
[System.IO.File]::WriteAllText($stamp, ('0' * 64))
try {
    $wrong = RunCli @('build', '--project', $projA, '--profile', 'normal') $cwd 300000
    Row 'profile_iscc_identity_exit' "$($wrong.Code)"
    Row 'profile_iscc_identity_cause' $(
        if ($wrong.Err -match 'pack_iscc_identity') { 'pack_iscc_identity' }
        else { 'other' })
    Require ($wrong.Code -eq 4) "W6: a drifted compiler pin exited $($wrong.Code)"
    Require ($wrong.Err -match 'pack_iscc_identity') `
        'W6: the refusal is not typed pack_iscc_identity'
    Require ($wrong.Err -match 'get-innosetup\.ps1') `
        'W6: the remediation does not name the provisioning script'
} finally {
    [System.IO.File]::WriteAllText($stamp, $stampWas)
}

# --- W7: an identity value carrying a metacharacter -------------------------
# It never reaches an Inno define because it never reaches a DESCRIPTOR:
# schema 1's grammars exclude every one of them and the reader refuses before
# the packaging driver is called at all. The derivation's OWN refusal is
# measured purely by the suite; this is the end-to-end half.
# SCAFFOLDED rather than copied: $projA now carries a ~500 MB artifacts
# tree, and copying it to edit one descriptor field would be half a gigabyte
# of I/O to prove a refusal that never reaches a build
$bad = Join-Path $spaced 'badident'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $bad
$mkBad = RunCli @('create', 'badident', '--ui', 'pas2js',
    '--bundle-id', 'com.example.badident') $spaced 300000
Require ($mkBad.Code -eq 0) "W7: the fixture project could not be created"
$desc = Join-Path $bad 'pweb.json'
$descText = [System.IO.File]::ReadAllText($desc)
[System.IO.File]::WriteAllText($desc,
    $descText.Replace('"name": "badident"', '"name": "bad{ident}"'))
$badRun = RunCli @('build', '--project', $bad, '--profile', 'normal') $cwd 300000
Row 'profile_identity_metacharacter_exit' "$($badRun.Code)"
Row 'profile_identity_metacharacter_refused' (Bool ($badRun.Code -eq 3))
Require ($badRun.Code -eq 3) `
    "W7: a metacharacter identity exited $($badRun.Code); the ratified refusal is 3"
Require (-not (Test-Path -LiteralPath (Join-Path (Join-Path $bad 'dist') $target))) `
    'W7: a refused identity produced an output directory'

# --- L1: the project-root ceiling, MEASURED on this runner ------------------
# Three roots, one build each: the largest that builds and the smallest that
# fails bracket the pinned bound, and this leg fails if the bound is not
# strictly between them. That is what turns a number somebody typed into a
# measurement, and it is the only honest way to own a ceiling whose real
# owner is a third-party compiler.
# the bound comes from contracts.json through the caller's row; a run whose
# contract check did not produce one has nothing to bracket, and says so
$boundText = "$($rows['long_path_bound_chars'])"
if ($boundText -notmatch '^\d+$') {
    Require $false ('L1: the project-root bound is ' + $boundText +
        ' -- the contract check did not run')
    foreach ($k in 'long_path_ok_chars', 'long_path_fail_chars',
                   'long_path_refusal', 'long_path_refusal_cause',
                   'long_path_refusal_exit') {
        Row $k 'unmeasured'
    }
    return
}
$bound = [int]$boundText
$probeRoot = Join-Path $work 'lp'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $probeRoot
New-Item -ItemType Directory -Force $probeRoot | Out-Null
$okChars = 0
$failChars = 0
Row 'long_path_refusal_cause' 'not_reached'
Row 'long_path_refusal_exit' '0'
foreach ($extra in -20, 20, 70) {
    $padLen = $bound - $probeRoot.Length - 8 + $extra
    if ($padLen -lt 1) { continue }
    $pad = Join-Path $probeRoot ('p' * $padLen)
    if ($pad.Length -gt 230) { continue }
    New-Item -ItemType Directory -Force $pad -ErrorAction SilentlyContinue | Out-Null
    if (-not (Test-Path -LiteralPath $pad)) { continue }
    $mk = RunCli @('create', 'lpdemo', '--ui', 'pas2js',
        '--bundle-id', 'com.example.lpdemo') $pad 300000
    if ($mk.Code -ne 0) { continue }
    $proj = Join-Path $pad 'lpdemo'
    $bp = RunCli @('build', '--project', $proj) $cwd 1800000
    Write-Host "[CAP-10D1] long path probe: $($proj.Length) chars -> exit $($bp.Code)"
    if ($bp.Code -eq 0) {
        if ($proj.Length -gt $okChars) { $okChars = $proj.Length }
    } else {
        if (($failChars -eq 0) -or ($proj.Length -lt $failChars)) {
            $failChars = $proj.Length
        }
        Row 'long_path_refusal_cause' $(
            if ($bp.Err -match 'project_root_too_long') { 'project_root_too_long' }
            else { 'other' })
        Row 'long_path_refusal_exit' "$($bp.Code)"
    }
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $proj
}
Row 'long_path_ok_chars' "$okChars"
Row 'long_path_fail_chars' "$failChars"
Row 'long_path_refusal' $(
    if ($failChars -gt 0) { 'measured' } else { 'not_reached' })
Require ($okChars -gt 0) 'L1: no probe root built at all'
Require ($okChars -le $bound) `
    "L1: a root of $okChars characters builds, and the bound refuses at $bound"
Require ($failChars -gt 0) `
    'L1: no probe root was refused, so the bound is not bracketed'
if ($failChars -gt 0) {
    Require ($failChars -gt $bound) `
        "L1: the bound $bound does not lie below the smallest refused root $failChars"
    Require ($rows['long_path_refusal_exit'] -eq '3') `
        "L1: the long-path refusal exited $($rows['long_path_refusal_exit'])"
    Require ($rows['long_path_refusal_cause'] -eq 'project_root_too_long') `
        'L1: the long-path refusal is not typed project_root_too_long'
}

# --- W1: install, launch, 42, uninstall, no residue -------------------------
# THE GUARD IS THE DIAGNOSTIC. Without an artifact there is nothing to
# install, and a gate that threw here would take its own evidence file with
# it - so the rows are typed, the failure is named, and the run still writes
# what it DID measure.
$setupA = $artifacts['normal']
if ($null -eq $setupA) {
    Require $false 'W1: the normal profile produced no artifact to install'
    foreach ($k in 'windows_install_exit', 'windows_installed_layout',
                   'windows_profile_marker', 'windows_installed_rpc',
                   'windows_uninstall_residue',
                   'windows_normal_install_run_uninstall',
                   'windows_profile_collision',
                   'windows_two_bundleids_side_by_side',
                   'windows_profile_self_replace') {
        Row $k 'unmeasured'
    }
    return
}
$installA = InstallDirFor 'com.example.demopack'
$r = InvokeBounded $setupA $silent 900000 'the normal setup'
Row 'windows_install_exit' "$($r.Code)"
Require ($r.Code -eq 0) "W1: the silent install exited $($r.Code)"
Require (Test-Path -LiteralPath $installA) `
    'W1: nothing was installed at the DERIVED directory'
# the installed layout is the release triple plus Inno's own two files, and
# nothing else - no loose frontend file, no provisioning payload, no helper
$installed = SortOrdinal @(Get-ChildItem -LiteralPath $installA -File -Force |
    ForEach-Object { $_.Name })
Row 'windows_installed_layout' ($installed -join ',')
$expectA = SortOrdinal @('app.pwb', 'demopack.exe', 'unins000.dat',
    'unins000.exe', 'webview.dll')
Require (($installed -join ',') -ceq ($expectA -join ',')) `
    ("W1: the installed layout is [" + ($installed -join ',') + ']')
# the profile marker says WHICH mode is installed, in PWeb's own namespace
$marker = ''
try {
    $marker = (Get-ItemProperty -LiteralPath (MarkerKeyFor 'com.example.demopack') `
        -Name 'Profile' -ErrorAction Stop).Profile
} catch { }
Row 'windows_profile_marker' "$marker"
Require ($marker -ceq 'normal') "W1: the profile marker reads '$marker'"
# AND IT RUNS
$env:PWEB_SMOKE_AUTOCLOSE_MS = '20000'
$ir = InvokeBounded (Join-Path $installA 'demopack.exe') @() 180000 `
    'the installed application'
Remove-Item Env:PWEB_SMOKE_AUTOCLOSE_MS -ErrorAction SilentlyContinue
Write-Host '----- the installed run -----'
Write-Host $ir.Out
$value = -1
foreach ($line in ($ir.Out -split "`n")) {
    if ($line -match '^\w+: ready (\{.*\})\s*$') {
        $value = ($Matches[1] | ConvertFrom-Json).value
    }
}
Row 'windows_installed_rpc' "$value"
Require ($value -eq 42) `
    "W1: the installed application answered $value rather than 42"
# AND IT UNINSTALLS, leaving nothing behind
Assert-PWebProcessDrained -Root $installA -What 'installed application' `
    -Names @('msedgewebview2.exe', 'demopack.exe')
$u = InvokeBounded (Join-Path $installA 'unins000.exe') $silent 300000 `
    'the uninstaller'
Require ($u.Code -eq 0) "W1: the silent uninstall exited $($u.Code)"
Start-Sleep -Milliseconds 2000
Assert-PWebProcessDrained -Root $installA -What 'installed application' `
    -Names @('msedgewebview2.exe', 'demopack.exe')
$residue = @()
if (Test-Path -LiteralPath $installA) {
    $residue = @(Get-ChildItem -LiteralPath $installA -Recurse -Force |
        ForEach-Object { $_.Name })
}
Row 'windows_uninstall_residue' "$($residue.Count)"
Require ($residue.Count -eq 0) `
    "W1: $($residue.Count) file(s) survived the uninstall"
Require (-not (Test-Path -LiteralPath (MarkerKeyFor 'com.example.demopack'))) `
    'W1: the profile marker survived the uninstall'
Require (-not (Test-Path -LiteralPath (UninstallKeyFor 'com.example.demopack'))) `
    'W1: the uninstall registration survived the uninstall'
Row 'windows_normal_install_run_uninstall' 'true'

# --- W4: two bundleIds side by side, and self-replacement -------------------
$rb = RunCli @('build', '--project', $projB, '--profile', 'normal') $cwd
Require ($rb.Code -eq 0) "W4: the second project's build exited $($rb.Code)"
$setupB = Join-Path (DistDirOf $projB 'normal') 'altpack-normal-setup.exe'
Require (Test-Path -LiteralPath $setupB) `
    'W4: the second project produced no artifact at its DERIVED basename'
[void](InvokeBounded $setupA $silent 900000 'demopack, again')
[void](InvokeBounded $setupB $silent 900000 'altpack')
$installB = InstallDirFor 'org.other.altpack'
$bothPresent = (Test-Path -LiteralPath (Join-Path $installA 'demopack.exe')) -and
               (Test-Path -LiteralPath (Join-Path $installB 'altpack.exe'))
Row 'windows_profile_collision' (Bool (-not $bothPresent))
Require $bothPresent `
    'W4: two projects with different bundleIds do not install side by side'
Require ($installA -cne $installB) 'W4: two projects share one install directory'
Require ((Test-Path -LiteralPath (UninstallKeyFor 'com.example.demopack')) -and
         (Test-Path -LiteralPath (UninstallKeyFor 'org.other.altpack'))) `
    'W4: the two projects do not have distinct uninstall registrations'
Require ((Test-Path -LiteralPath (MarkerKeyFor 'com.example.demopack')) -and
         (Test-Path -LiteralPath (MarkerKeyFor 'org.other.altpack'))) `
    'W4: the two projects do not have distinct profile markers'
Row 'windows_two_bundleids_side_by_side' 'true'
# SELF-REPLACEMENT: the same bundleId re-installed keeps ONE registration
[void](InvokeBounded $setupA $silent 900000 'demopack, a third time')
$registrations = @(Get-ChildItem `
    -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' |
    Where-Object { $_.PSChildName -like 'com.example.demopack*' })
Row 'windows_profile_self_replace' (Bool ($registrations.Count -eq 1))
Require ($registrations.Count -eq 1) `
    "W4: a rebuilt project has $($registrations.Count) uninstall registration(s)"
UninstallIfPresent 'com.example.demopack'
UninstallIfPresent 'org.other.altpack'
