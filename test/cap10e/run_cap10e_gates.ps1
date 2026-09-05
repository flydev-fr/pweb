# CAP-10E Windows gates: the kernel-resolved image path on the platform the
# defect actually lived on.
#
#   E1/E9  the image-path probe at a directory carrying a SPACE and a
#          non-ASCII character. It records the kernel's answer, the CLI
#          seam's answer and - deliberately - the RTL's, so the defect stays
#          visible after the fix instead of becoming a changelog claim. On
#          this platform rtl_equals_kernel is FALSE at such a path, and that
#          row is the measurement the whole shard rests on.
#   E2     the release host at that directory answers 42, launched from an
#          unrelated working directory, with nothing but exe + app.pwb + dll
#          beside it. Same conditional hosted policy as its sibling gates
#          (test/cap6/run_cap6_smoke.ps1): a genuine failure gates, only an
#          absent WebView2/desktop session records SKIP.
#   E6     A REAL JUNCTION on the image path chain, MEASURED rather than
#          asserted - and the brief's expectation is corrected here rather
#          than quietly satisfied. There is nothing for the host to refuse:
#          GetModuleFileNameW returns the path the loader was GIVEN, so
#          app.pwb resolves through the same junction to the same file, and
#          a junction cannot make a trusted binary read a bundle from a
#          directory other than the one it was launched from. What CAN be
#          asked is whether the BUNDLE FILE ITSELF may be a reparse point,
#          and that is asked too - as an observation, because changing the
#          answer would change which file is loaded on previously-green
#          layouts and this shard is forbidden to do that.
#   E7     an image directory longer than MAX_PATH. The ratified rule is
#          that the helper returns the kernel's path VERBATIM - no \\?\
#          prefix, which the CAP-6b3 shape policy refuses by name - over a
#          32767-wide buffer, so the one thing that must never happen is a
#          silent truncation. That is the assertion; whether Windows will
#          then start and run the process from such a path is MEASURED and
#          recorded with its cause, in the CAP-10D1 long_path vocabulary.
#
# Emits build/cap10e/image-path-windows-<arch>.json.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot
$work = Join-Path $repoRoot 'build/cap10e'
New-Item -ItemType Directory -Force $work | Out-Null

# THE RATIFIED QUOTING HELPER, and nowhere is it more load-bearing than
# here: `Start-Process -ArgumentList <array>` joins without quoting, and
# every path this gate launches from carries a SPACE and a non-ASCII
# character by design. C0-12 (b) / C1-11 (a), enforced across every CAP-10
# gate by test/cap10d0/check_cap10d0_contracts.ps1 - which is where this
# gate's first hosted run was refused for calling Start-Process directly.
. (Join-Path $repoRoot 'test/cap10d0/psargs.ps1')

$rows = New-Object System.Collections.Generic.List[string]
$violations = New-Object System.Collections.Generic.List[string]
function Row([string]$Name, [string]$Value) { $rows.Add("$Name=$Value") }
function Require([bool]$Ok, [string]$Message) {
    if (-not $Ok) {
        Write-Host "[CAP-10E] GATE FAILURE: $Message"
        $violations.Add($Message)
    }
}
function Bool([bool]$V) { if ($V) { 'true' } else { 'false' } }

$arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') {
    'arm64' } else { 'x86_64' }
$target = "windows-$arch"
Row 'schema' '1'
Row 'target' $target

foreach ($pre in 'build/cap6/release/releaseapp.exe',
                 'build/cap6/release/app.pwb',
                 'build/cap6/release/webview.dll') {
    if (-not (Test-Path $pre)) {
        throw ("missing precondition: $pre -- run test/cap6/run_cap6_gates.ps1 " +
            'first (it assembles the release directory this gate relocates)')
    }
}

# --- IS THE INSTRUMENT IN THE THING UNDER TEST? ------------------------------
# This gate relocates a binary ANOTHER gate built, so it can be handed a
# pre-CAP-10E host and would then measure the defect and call it a failure of
# the fix. That is not hypothetical: the first local run of this gate did
# exactly that, and the ledger already carries the general form of the
# mistake ("a reproduction must name the artifact the build just produced").
# So the binary is asked, before anything else, whether it contains the
# refusal string CAP-10E introduced. A pre-CAP-10E host does not.
$freshNeedle = 'image path unavailable'
$hostBytes = [System.IO.File]::ReadAllBytes('build/cap6/release/releaseapp.exe')
$hostText = [System.Text.Encoding]::ASCII.GetString($hostBytes)
$hostFresh = $hostText.Contains($freshNeedle)
Row 'host_binary_carries_cap10e' (Bool $hostFresh)
if (-not $hostFresh) {
    throw ('build/cap6/release/releaseapp.exe predates CAP-10E (it does not ' +
        "carry `"$freshNeedle`") -- rebuild it with test/cap6/build_cap6.ps1 " +
        'and re-assemble the release directory. Measuring a stale binary here ' +
        'would report the defect as a failure of its own fix.')
}

# the PASS marker from the host's OWN constant - the single-source discipline
# test/cap7m/run_cap7m_release.sh applies, and for the same reason
$markerConst = @(Select-String -Path examples/08-release/releaseapp.pas `
    -Pattern "^  VERDICT_PASS = '([^']+)';$" -CaseSensitive)
if ($markerConst.Count -ne 1) {
    throw "expected one VERDICT_PASS constant in releaseapp.pas, found $($markerConst.Count)"
}
$passMarker = 'releaseapp' + $markerConst[0].Matches[0].Groups[1].Value
Write-Host "[CAP-10E] canonical release marker: $passMarker"

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("cap10e-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $sandbox | Out-Null
# the accented + spaced leaf, composed from the code point rather than typed,
# so the character cannot be lost to this file's own encoding
$accentLeaf = ([char]0x00E9) + 'tude cap10e'

try {

# --- E1/E9: the probe -------------------------------------------------------
Write-Host "`n[CAP-10E] === E1/E9 the image-path probe at a non-ASCII directory"
$mormot = @('-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
    '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt',
    '-Fudeps/mormot2/src/net', '-Fudeps/mormot2/src/db',
    '-Fudeps/mormot2/src/orm', '-Fudeps/mormot2/src/rest',
    '-Fudeps/mormot2/src/soa')
New-Item -ItemType Directory -Force "$work/probe-units", "$work/probe-bin" | Out-Null
fpc -Px86_64 -Twin64 -MObjFPC -Sh -B -FU"$work/probe-units" -FE"$work/probe-bin" `
    -Fusrc/security -Futools/pweb -Fusrc/rpc -Fusrc/assets -Fusrc/platform/windows `
    @mormot -Fldeps/mormot2/static/x86_64-win64 test/cap10e/imageprobe.pas |
    Out-File -Encoding utf8 "$work/probe-build.log"
if ($LASTEXITCODE -ne 0) {
    Get-Content "$work/probe-build.log" | Select-Object -Last 25 | Write-Host
    throw 'the CAP-10E probe compile FAILED'
}

function Invoke-Probe([string]$Dir, [string]$Tag) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $exe = Join-Path $Dir 'imageprobe.exe'
    Copy-Item -Force "$work/probe-bin/imageprobe.exe" $exe
    $out = Join-Path $work "probe-$Tag.txt"
    Remove-Item -Force -ErrorAction SilentlyContinue $out
    $p = Start-PWebProcess -FilePath $exe -NoNewWindow -Wait -PassThru `
        -WorkingDirectory ([System.IO.Path]::GetTempPath()) -RedirectStandardOutput $out
    $text = if (Test-Path -LiteralPath $out) {
        [System.IO.File]::ReadAllText($out) } else { '' }
    return @{ Code = $p.ExitCode; Text = $text }
}
function Probe-Value([string]$Text, [string]$Name) {
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.StartsWith("$Name=")) { return $line.Substring($Name.Length + 1) }
    }
    return ''
}

$probeDir = Join-Path $sandbox $accentLeaf
$probe = Invoke-Probe $probeDir 'nonascii'
Write-Host $probe.Text
Row 'image_path_source'    (Probe-Value $probe.Text 'image_path_source')
Row 'image_dir_non_ascii'  (Probe-Value $probe.Text 'image_dir_non_ascii')
Row 'image_dir_hex'        (Probe-Value $probe.Text 'image_dir_hex')
Row 'cli_equals_helper'    (Probe-Value $probe.Text 'cli_equals_helper')
Row 'rtl_equals_kernel'    (Probe-Value $probe.Text 'rtl_equals_kernel')
Row 'probe_verdict'        (Probe-Value $probe.Text 'verdict')
Require ((Probe-Value $probe.Text 'verdict') -eq 'PASS') `
    'E9: the probe did not answer PASS'
Require ((Probe-Value $probe.Text 'image_dir_non_ascii') -eq 'true') `
    'E1: the probe directory carries no non-ASCII character - an ASCII path measures the shape that never failed'
Require ((Probe-Value $probe.Text 'cli_equals_helper') -eq 'true') `
    'E9: the CLI seam and the shipped helper disagreed on the image directory'
# THE DEFECT, asserted rather than narrated: on this platform, at this path,
# the RTL's answer must DIFFER from the kernel's. If it ever stops differing
# the defect is gone from the RTL and this row should be re-read, not deleted
Require ((Probe-Value $probe.Text 'rtl_equals_kernel') -eq 'false') `
    'E1: the RTL agreed with the kernel at a non-ASCII path - the measurement this shard rests on no longer reproduces; re-read it before trusting either'

# --- E2: the release host at the accented directory -------------------------
Write-Host "`n[CAP-10E] === E2 the release host at a non-ASCII directory"
$relDir = Join-Path $probeDir 'release'
New-Item -ItemType Directory -Force $relDir | Out-Null
foreach ($f in 'releaseapp.exe', 'app.pwb', 'webview.dll') {
    Copy-Item -Force (Join-Path 'build/cap6/release' $f) (Join-Path $relDir $f)
}
function Invoke-Host([string]$Exe, [string]$Tag) {
    $so = Join-Path $work "run-$Tag-stdout.txt"
    $se = Join-Path $work "run-$Tag-stderr.txt"
    Remove-Item -Force -ErrorAction SilentlyContinue $so, $se
    $env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'
    try {
        $p = Start-PWebProcess -FilePath $Exe -NoNewWindow -PassThru `
            -WorkingDirectory ([System.IO.Path]::GetTempPath()) `
            -RedirectStandardOutput $so -RedirectStandardError $se
        if (-not $p.WaitForExit(180000)) {
            try { $p.Kill() } catch { }
            $p.WaitForExit(10000) | Out-Null
            return @{ Code = -999; Text = 'the run did not exit inside 180 s' }
        }
        $p.WaitForExit()
        $text = ''
        foreach ($f in @($so, $se)) {
            if (Test-Path -LiteralPath $f) { $text += [System.IO.File]::ReadAllText($f) }
        }
        return @{ Code = $p.ExitCode; Text = $text }
    } finally {
        Remove-Item Env:PWEB_SMOKE_AUTOCLOSE_MS -ErrorAction SilentlyContinue
    }
}
# the sibling gates' conditional hosted policy, restated so a runner without a
# WebView2 runtime records SKIP instead of a red that means nothing
function Classify([hashtable]$Run) {
    if (($Run.Code -eq 0) -and ($Run.Text -match [regex]::Escape($passMarker))) { return '42' }
    if ($Run.Text -match 'WEBVIEW2 RUNTIME UNUSABLE') { return 'skip_no_runtime' }
    if ($Run.Text -match 'webview_create \(returned nil') { return 'skip_no_session' }
    return '-1'
}

$r = Invoke-Host (Join-Path $relDir 'releaseapp.exe') 'nonascii'
Write-Host $r.Text
$verdict2 = Classify $r
Row 'nonascii_release_exit' "$($r.Code)"
Row 'nonascii_release_host' $verdict2
Require ($verdict2 -ne '-1') `
    "E2: the release host at a non-ASCII directory did not answer 42 (exit $($r.Code))"

# --- E6: a REAL junction on the image path chain ----------------------------
Write-Host "`n[CAP-10E] === E6 a junction on the image path chain"
$realDir = Join-Path $sandbox 'real'
New-Item -ItemType Directory -Force $realDir | Out-Null
foreach ($f in 'releaseapp.exe', 'app.pwb', 'webview.dll') {
    Copy-Item -Force (Join-Path 'build/cap6/release' $f) (Join-Path $realDir $f)
}
$junction = Join-Path $sandbox 'link'
# mklink /J through cmd: New-Item -ItemType Junction exists but the cmd form
# is what every other Windows gate in this repository uses
& cmd.exe /c mklink /J "`"$junction`"" "`"$realDir`"" | Out-Null
$junctionMade = Test-Path -LiteralPath (Join-Path $junction 'releaseapp.exe')
Row 'junction_created' (Bool $junctionMade)
Require $junctionMade 'E6: the junction could not be created - the leg measured nothing'

if ($junctionMade) {
    $jp = Invoke-Probe (Join-Path $junction 'probe') 'junction'
    $jImage = Probe-Value $jp.Text 'image_dir'
    # the kernel reports the path the LOADER was given, junction and all: the
    # helper resolves nothing further, which is the ratified rule
    Row 'junction_image_dir_via_link' (Bool ($jImage -like "*$([System.IO.Path]::GetFileName($junction))*"))
    $jr = Invoke-Host (Join-Path $junction 'releaseapp.exe') 'junction'
    Write-Host $jr.Text
    $jVerdict = Classify $jr
    Row 'junction_release_host' $jVerdict
    # NOT "refused". A directory junction on the chain is TRANSPARENT: it
    # names the same file, so there is no redirection to refuse. The property
    # that matters - a junction cannot make the host read a bundle from some
    # OTHER directory - holds by construction, and this row records the
    # measurement rather than a claim the repository does not implement.
    Row 'junction_on_chain' $(if ($jVerdict -eq '42') { 'transparent_same_file' }
                              elseif ($jVerdict -like 'skip_*') { $jVerdict }
                              else { 'refused' })
    Require ($jVerdict -ne '-1') `
        "E6: the host launched through a junction neither answered 42 nor skipped (exit $($jr.Code))"

    # the question the trusted model DOES answer: may the BUNDLE FILE itself
    # be a reparse point? Measured, never legislated - changing this answer
    # would change which file is loaded on a previously-green layout.
    $reparseDir = Join-Path $sandbox 'reparse'
    New-Item -ItemType Directory -Force $reparseDir | Out-Null
    foreach ($f in 'releaseapp.exe', 'webview.dll') {
        Copy-Item -Force (Join-Path 'build/cap6/release' $f) (Join-Path $reparseDir $f)
    }
    & cmd.exe /c mklink "`"$(Join-Path $reparseDir 'app.pwb')`"" `
        "`"$(Join-Path $realDir 'app.pwb')`"" 2>&1 | Out-Null
    $linkMade = Test-Path -LiteralPath (Join-Path $reparseDir 'app.pwb')
    Row 'bundle_file_symlink_created' (Bool $linkMade)
    if ($linkMade) {
        $lr = Invoke-Host (Join-Path $reparseDir 'releaseapp.exe') 'bundlelink'
        $lVerdict = Classify $lr
        Row 'bundle_file_reparse' $(if ($lVerdict -eq '42') { 'accepted' }
                                    elseif ($lVerdict -like 'skip_*') { $lVerdict }
                                    else { 'refused' })
    } else {
        # a symbolic link needs SeCreateSymbolicLinkPrivilege or developer
        # mode; an unprivileged runner records that rather than a verdict
        Row 'bundle_file_reparse' 'unmeasured_no_privilege'
    }
}

# --- E7: an image directory longer than MAX_PATH ----------------------------
Write-Host "`n[CAP-10E] === E7 an image directory longer than MAX_PATH"
# WHY the leg resolved or did not, recorded so a reader never has to guess:
# without LongPathsEnabled Windows refuses to START a process from a path
# over MAX_PATH, which happens before any PWeb code exists and is therefore
# the OS's answer rather than the helper's.
$lpe = 0
try {
    $lpe = [int](Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
        -Name 'LongPathsEnabled' -ErrorAction Stop)
} catch { $lpe = 0 }
Row 'long_paths_enabled' (Bool ($lpe -eq 1))

$deep = $sandbox
while ($deep.Length -lt 300) { $deep = Join-Path $deep ('d' * 40) }
# \\?\ ONLY to CREATE the tree: the Win32 path limit is a parsing rule, and
# this is the documented way past it. Nothing is launched through that form -
# the process is started by the ordinary path, so what the kernel reports is
# what an ordinary long installation would report.
[void][System.IO.Directory]::CreateDirectory("\\?\$deep")
Row 'long_path_image_dir_chars' "$($deep.Length)"
$deepOk = Test-Path -LiteralPath "\\?\$deep"
Row 'long_path_dir_created' (Bool $deepOk)
if ($deepOk) {
    [System.IO.File]::Copy("$work/probe-bin/imageprobe.exe",
        "\\?\$deep\imageprobe.exe", $true)
    $lo = Join-Path $work 'probe-longpath.txt'
    # TWO ATTEMPTS, in this order and for a stated reason. The PLAIN form is
    # what an ordinary long installation looks like, so it is tried first and
    # its outcome is the honest headline. If Windows refuses to start a
    # process from it - which it does wherever LongPathsEnabled is off, and
    # did on the dev host - the DEVICE form is tried, because the assertion
    # this leg actually owns is about the helper and not about the OS: over a
    # 32767-wide buffer the kernel's answer must never come back truncated,
    # and that can only be measured on a process that actually started.
    $form = ''
    $lt = ''
    foreach ($attempt in @(
        @{ Form = 'plain';  Path = "$deep\imageprobe.exe" },
        @{ Form = 'device'; Path = "\\?\$deep\imageprobe.exe" })) {
        Remove-Item -Force -ErrorAction SilentlyContinue $lo
        try {
            $p = Start-PWebProcess -FilePath $attempt.Path -NoNewWindow -Wait -PassThru `
                -WorkingDirectory ([System.IO.Path]::GetTempPath()) -RedirectStandardOutput $lo
            if (($p.ExitCode -eq 0) -and (Test-Path -LiteralPath $lo)) {
                $lt = [System.IO.File]::ReadAllText($lo)
                if ($lt.Trim()) { $form = $attempt.Form; break }
            }
        } catch {
            # the OS's own refusal, kept in the log rather than in a compared
            # row: the message is LOCALIZED, and a localized string in
            # cross-target evidence is a false difference waiting to happen
            Write-Host ("[CAP-10E] long path, $($attempt.Form) form: " +
                ($_.Exception.Message -replace '[\r\n]+', ' '))
        }
    }
    Row 'long_path_launch_form' $(if ($form) { $form } else { 'none' })
    if ($form) {
        Write-Host $lt
        $reported = Probe-Value $lt 'image_dir'
        Row 'long_path_image_dir_reported_chars' "$($reported.Length)"
        # THE assertion this leg owns: no silent truncation. GetModuleFileNameW
        # returns 0 on failure and the buffer size on truncation, and the
        # helper refuses both - so a short answer here would be a bug, not a
        # limitation.
        $notTruncated = ($reported.Length -ge $deep.Length)
        Row 'long_path_image_truncated' (Bool (-not $notTruncated))
        Require $notTruncated `
            "E7: the image path came back truncated ($($reported.Length) chars for a $($deep.Length)-char directory)"
        # WHAT THE KERNEL SPELLED BACK. The helper adds no \\?\ prefix; if one
        # is present it is because the loader was GIVEN one, and that matters
        # beyond curiosity: PWebWv2FixedPathShapeOk refuses the device form by
        # name, so a fixed-runtime profile launched that way would refuse. It
        # is recorded here and named in the shard's known limitations.
        Row 'long_path_image_device_form' (Bool ($reported.StartsWith('\\?\')))
        Row 'long_path_outcome' "resolved_$form"
    } else {
        Row 'long_path_image_dir_reported_chars' '0'
        Row 'long_path_image_truncated' 'not_applicable'
        Row 'long_path_image_device_form' 'not_applicable'
        Row 'long_path_outcome' 'process_start_refused_by_os'
    }
} else {
    Row 'long_path_launch_form' 'none'
    Row 'long_path_image_dir_reported_chars' '0'
    Row 'long_path_image_truncated' 'not_applicable'
    Row 'long_path_image_device_form' 'not_applicable'
    Row 'long_path_outcome' 'directory_creation_refused'
}

# --- E4: the fixed-runtime profile at an accented install directory ---------
# The measurement itself belongs with the installer, so it is made by the
# CAP-6b3 gate body run a SECOND time with -InstallLeaf pointing at an
# accented directory - parameterised, never copied - and this gate only
# carries its verdict into the evidence. A record that is absent says so
# rather than being quietly filled in.
$fixedRec = Join-Path $repoRoot 'build/cap6b3/fixed-nonascii.json'
if (Test-Path $fixedRec) {
    $fr = Get-Content $fixedRec -Raw | ConvertFrom-Json
    Row 'fixed_profile_install_dir_non_ascii' "$($fr.install_dir_non_ascii)"
    Row 'fixed_profile_nonascii_dir' "$($fr.fixed_profile_nonascii_dir)"
    Require ("$($fr.install_dir_non_ascii)" -ceq 'true') `
        'E4: the CAP-6b3 accented run installed to a directory with no non-ASCII character'
    Require ("$($fr.fixed_profile_nonascii_dir)" -in @('42', 'skip_no_session')) `
        "E4: the fixed profile at an accented directory answered $($fr.fixed_profile_nonascii_dir)"
} else {
    Row 'fixed_profile_install_dir_non_ascii' 'not_run'
    Row 'fixed_profile_nonascii_dir' 'not_run'
}
Row 'symlink_rule' 'posix_only'

} finally {
    # the junction is removed as a DIRECTORY ENTRY, never walked: Remove-Item
    # -Recurse on a junction has historically deleted the target's contents
    foreach ($j in @((Join-Path $sandbox 'link'))) {
        if (Test-Path -LiteralPath $j) { [System.IO.Directory]::Delete($j, $false) }
    }
    # the recursive delete is CONFINED before it runs, not trusted because of
    # where the variable came from: this gate creates junctions and a
    # 318-character tree, and both are exactly the shapes a careless cleanup
    # gets wrong. $sandbox must still be a GUID-named child of the temp
    # directory or nothing is deleted at all.
    $tempRoot = [System.IO.Path]::GetTempPath().TrimEnd('\')
    $sandboxLeaf = Split-Path -Leaf $sandbox
    if (($sandbox -like "$tempRoot\*") -and
        ($sandboxLeaf -match '^cap10e-[0-9a-f]{32}$') -and
        (Test-Path -LiteralPath $sandbox)) {
        # the deep tree needs the \\?\ form to be removable at all;
        # Directory.Delete does not follow reparse points, it removes them
        try { [System.IO.Directory]::Delete("\\?\$sandbox", $true) } catch { }
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -LiteralPath $sandbox
    } elseif (Test-Path -LiteralPath $sandbox) {
        Write-Host ("[CAP-10E] REFUSING to remove '$sandbox': it is not a " +
            'GUID-named child of the temp directory')
    }
}

Row 'violations' "$($violations.Count)"
Row 'verdict' $(if ($violations.Count -eq 0) { 'PASS' } else { 'FAIL' })
$rowsFile = Join-Path $work "rows-$target.txt"
[System.IO.File]::WriteAllText($rowsFile, (($rows -join "`n") + "`n"),
    [System.Text.UTF8Encoding]::new($false))
$digest = (Get-FileHash $rowsFile -Algorithm SHA256).Hash.ToLowerInvariant()
$facts = [ordered]@{ schema = 1; target = $target; image_path_digest = $digest }
foreach ($line in $rows) {
    $i = $line.IndexOf('=')
    $k = $line.Substring(0, $i)
    if ($k -in @('schema', 'target')) { continue }
    $facts[$k] = $line.Substring($i + 1)
}
[System.IO.File]::WriteAllText((Join-Path $work "image-path-$target.json"),
    (($facts | ConvertTo-Json -Depth 4) + "`n"), [System.Text.UTF8Encoding]::new($false))
Write-Host ($facts | ConvertTo-Json -Depth 4)

if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Write-Host "VIOLATION: $v" }
    throw "CAP-10E Windows gates FAILED: $($violations.Count) violation(s)"
}
Write-Host "[CAP-10E] Windows gates PASS on $target (digest $digest)"
