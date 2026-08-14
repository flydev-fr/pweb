# CAP-6b1: builds dist/windows/normal/PWebRelease-Normal-Setup.exe -
# the normal-profile per-user installer embedding the lock-verified
# Evergreen Bootstrapper.
#
# The artifact basename is authored in tools/setup/normal.iss
# (PWEB_SETUP_BASENAME) and PARSED here, never passed with /F: the
# manifest stays the single source of the name, and no artifact this
# repository ships is called setup.exe (CAP-6b4 - every executable with
# that name is appcompat-shimmed into loading extra DLLs from its own
# directory).
#
#   1. provisions the pinned Inno Setup 6 compiler (innosetup.lock)
#   2. fetches the LOCKED bootstrapper through webview2-runtime.lock
#      (sha256 + Authenticode subject verified; upstream drift fails
#      the build and deletes the download; NOTHING is executed here)
#   3. compiles the pwebwv2prov setup helper (frozen CAP-6b0 policy
#      reused through pweb.platform.webview2.provision)
#   4. stages the payload: the unchanged CAP-6 release triple from
#      build/cap6/release + bootstrapper + helper, re-verifying the
#      staged bootstrapper against the lock digest (defense in depth)
#   5. compiles tools/setup/normal.iss with every expected value
#      derived from the lock at THIS build moment - the helper's
#      arguments can never drift from the ratified pin; the bounded
#      timeout is parsed from PWEB_WV2_INSTALL_TIMEOUT_MS in the
#      provisioning unit (single source, house 1587-cross-check idiom)
#   6. TEST MODE (always built, never shipped): compiles a tiny
#      always-fail stub helper (exit 3) and builds a second
#      abort-probe setup embedding it via the documented
#      PWEB_PROV_HELPER test hook, so the gates can PROVE that a
#      failing helper aborts the setup with nothing installed
#
# The lock facts used are exported to build/cap6b1/lockfacts.psd1 so
# the gate scripts consume the exact same parse.
#
# Preconditions: build/cap6/release assembled by test/cap6/run_cap6_gates.ps1
# (which needs build_cap6.ps1 + the React dist), fpc on PATH.
#
# Usage: pwsh -File test/cap6b1/build_normal_setup.ps1

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Push-Location $RepoRoot
try {
    foreach ($pre in 'build/cap6/release/releaseapp.exe',
                     'build/cap6/release/app.pwb',
                     'build/cap6/release/webview.dll') {
        if (-not (Test-Path $pre)) {
            throw ("missing precondition: $pre -- run " +
                'test/cap6/run_cap6_gates.ps1 first (it assembles the release dir)')
        }
    }

    # --- 1) pinned Inno Setup 6 ------------------------------------------------
    pwsh -NoProfile -File tools/get-innosetup.ps1
    if ($LASTEXITCODE -ne 0) { throw 'pinned Inno Setup provisioning failed' }
    $Iscc = Join-Path $RepoRoot 'deps/innosetup/ISCC.exe'
    if (-not (Test-Path $Iscc)) { throw "ISCC.exe missing at $Iscc" }

    # --- 2) locked bootstrapper (verified fetch, never executed) ---------------
    pwsh -NoProfile -File tools/get-webview2-runtime.ps1 `
        -Artifact evergreen-bootstrapper
    if ($LASTEXITCODE -ne 0) {
        throw 'locked bootstrapper fetch-verify failed (upstream drift? see error above)'
    }

    # --- lock facts: one strict, targeted parse of the ratified entry ----------
    # (the authoritative validation already ran inside the fetch above;
    # this parse only extracts the ratified values for the /D defines)
    $lockLines = Get-Content (Join-Path $RepoRoot 'webview2-runtime.lock')
    $facts = @{}
    # the OTHER two profiles' artifacts are parsed for one reason only:
    # the payload proof below asserts their ABSENCE from this profile's
    # embedded set (CAP-6b4 isolation, mirroring the CAP-6b2/6b3 builds)
    $saFacts = @{}
    $fxFacts = @{}
    $section = ''
    foreach ($raw in $lockLines) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $k, $v = $line -split '=', 2
        $k = $k.Trim(); $v = $v.Trim()
        if ($k -ceq 'artifact') { $section = $v; continue }
        if ($section -ceq 'evergreen-bootstrapper') { $facts[$k] = $v }
        elseif ($section -ceq 'evergreen-standalone-x64') { $saFacts[$k] = $v }
        elseif ($section -ceq 'webview2-fixed-runtime-x64') { $fxFacts[$k] = $v }
    }
    foreach ($other in @(@{ n = 'evergreen-standalone-x64'; f = $saFacts },
                         @{ n = 'webview2-fixed-runtime-x64'; f = $fxFacts })) {
        if (-not $other.f['filename']) {
            throw "webview2-runtime.lock: $($other.n) is missing 'filename'"
        }
    }
    $SaFile = $saFacts['filename']
    $FxFile = $fxFacts['filename']
    foreach ($key in 'filename', 'sha256', 'authenticode-subject') {
        if (-not $facts[$key]) {
            throw "webview2-runtime.lock: evergreen-bootstrapper is missing '$key'"
        }
    }
    $BootFile = $facts['filename']
    $BootSha = $facts['sha256']
    $BootSubject = $facts['authenticode-subject']
    $BootPath = Join-Path $RepoRoot "deps/webview2-runtime/$BootFile"
    if (-not (Test-Path $BootPath)) { throw "verified bootstrapper missing: $BootPath" }

    # the ratified bounded wait: parsed from the Pascal constant so the
    # unit stays the single source (mirrors the 1587 cross-check idiom)
    $provUnit = Get-Content (Join-Path $RepoRoot `
        'src/platform/windows/pweb.platform.webview2.provision.pas') -Raw
    if ($provUnit -notmatch 'PWEB_WV2_INSTALL_TIMEOUT_MS\s*=\s*(\d+)\s*;') {
        throw 'PWEB_WV2_INSTALL_TIMEOUT_MS constant not found in the provisioning unit'
    }
    $TimeoutMs = [int]$Matches[1]
    if ($TimeoutMs -ne 900000) {
        throw "ratified timeout is 900000 ms, the unit says $TimeoutMs"
    }

    # --- 3) compile the setup helper -------------------------------------------
    New-Item -ItemType Directory -Force build/cap6b1/fpc, build/cap6b1/bin,
        build/cap6b1/payload | Out-Null
    fpc -MObjFPC -Sh -B -FUbuild/cap6b1/fpc -FEbuild/cap6b1/bin `
        -Fusrc/platform/windows `
        -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib `
        -Fudeps/mormot2/src/crypt `
        tools/setup/pwebwv2prov.pas
    if ($LASTEXITCODE -ne 0) { throw 'pwebwv2prov helper compile failed' }

    # --- 4) stage the payload ---------------------------------------------------
    $Payload = (Resolve-Path build/cap6b1/payload).Path
    Get-ChildItem $Payload -File | Remove-Item -Force
    Copy-Item build/cap6/release/releaseapp.exe $Payload/
    Copy-Item build/cap6/release/app.pwb $Payload/
    Copy-Item build/cap6/release/webview.dll $Payload/
    Copy-Item $BootPath $Payload/
    Copy-Item build/cap6b1/bin/pwebwv2prov.exe $Payload/
    # defense in depth: what gets EMBEDDED equals the ratified bytes
    $staged = (Get-FileHash -Algorithm SHA256 `
        (Join-Path $Payload $BootFile)).Hash.ToLowerInvariant()
    if ($staged -cne $BootSha) {
        Remove-Item -Force (Join-Path $Payload $BootFile)
        throw "staged bootstrapper sha256 drifted: expected $BootSha, got $staged"
    }

    # --- 5) compile the setup ---------------------------------------------------
    # the artifact basename is the manifest's, parsed from it: no /F
    # override, so a rename in the .iss can never leave the build script
    # looking for a file ISCC no longer produces
    $IssFile = Join-Path $RepoRoot 'tools/setup/normal.iss'
    $issText = Get-Content $IssFile -Raw
    if ($issText -notmatch '(?m)^#define\s+PWEB_SETUP_BASENAME\s+"([^"]+)"\s*$') {
        throw 'tools/setup/normal.iss does not author the PWEB_SETUP_BASENAME define'
    }
    $SetupBase = $Matches[1]
    if ($SetupBase -ieq 'setup') {
        throw 'the normal profile may not be named setup: setup.exe is appcompat-shimmed'
    }
    $DistDir = Join-Path $RepoRoot 'dist/windows/normal'
    New-Item -ItemType Directory -Force $DistDir | Out-Null
    # the compile listing is captured (as the CAP-6b2/6b3 builds already
    # do) and asserted below, and the CAP-6b4 isolation matrix reads the
    # same record to prove this profile against the other two
    $ListingFile = Join-Path $RepoRoot 'build/cap6b1/iscc-normal.log'
    & $Iscc "/DPWEB_PAYLOAD_DIR=$Payload" `
        "/DPWEB_WV2_BOOTSTRAPPER=$BootFile" `
        "/DPWEB_WV2_SHA256=$BootSha" `
        "/DPWEB_WV2_SUBJECT=$BootSubject" `
        "/DPWEB_WV2_TIMEOUT_MS=$TimeoutMs" `
        "/O$DistDir" tools/setup/normal.iss 2>&1 |
        Tee-Object -FilePath $ListingFile
    if ($LASTEXITCODE -ne 0) { throw 'ISCC compile of normal.iss failed' }
    $SetupExe = Join-Path $DistDir "$SetupBase.exe"
    if (-not (Test-Path $SetupExe)) { throw "normal setup missing at $SetupExe" }

    # --- 5b) payload proof from the compile listing -----------------------------
    # the same assertion the CAP-6b2 and CAP-6b3 builds make, applied to
    # this profile: the listing is authoritative evidence of what ISCC
    # actually embedded, and it is checked HERE rather than only in the
    # CAP-6b4 isolation gate, so a payload defect fails its own build.
    # This is a payload assertion only - nothing about CAP-6b1
    # provisioning semantics is touched.
    $listing = Get-Content $ListingFile -Raw
    # one basename per embedded file: ISCC may append a parenthesized
    # progress/size suffix, and a progress refresh may repeat a line -
    # strip the suffix, keep unique basenames (our staged names are
    # unique by construction, so collapsing repeats loses nothing)
    $compressed = @(($listing -split "`r?`n") |
        Where-Object { $_ -match '^\s*Compressing: ' } |
        ForEach-Object {
            (($_ -replace '^\s*Compressing: ', '') -replace '\s+\([^)]*\)\s*$', '').Trim()
        } | ForEach-Object { Split-Path -Leaf $_ } | Sort-Object -Unique)
    if ($compressed.Count -eq 0) {
        throw ('compile listing contains no "Compressing:" lines - ISCC output ' +
            "format changed? see $ListingFile")
    }
    $expectedSet = @('app.pwb', $BootFile, 'pwebwv2prov.exe', 'releaseapp.exe',
        'webview.dll') | Sort-Object
    if (($compressed -join ',') -cne ($expectedSet -join ',')) {
        throw ("embedded payload set drifted: listing shows [$($compressed -join ', ')], " +
            "expected exactly [$($expectedSet -join ', ')]")
    }
    if ($compressed -cnotcontains $BootFile) {
        throw "bootstrapper '$BootFile' missing from the embedded payload listing"
    }
    if ($listing -match [regex]::Escape($SaFile)) {
        throw ("NORMAL INVARIANT BROKEN: the Standalone Installer '$SaFile' appears " +
            'in the normal compile listing')
    }
    if ($listing -match [regex]::Escape($FxFile)) {
        throw ("NORMAL INVARIANT BROKEN: the Fixed Runtime cabinet '$FxFile' appears " +
            'in the normal compile listing')
    }
    if ($listing -match '(?i)msedgewebview2') {
        throw 'NORMAL INVARIANT BROKEN: a Fixed Runtime tree file appears in the listing'
    }
    $loose = @($compressed | Where-Object { $_ -match '\.(html|css|js|map|json)$' })
    if ($loose) {
        throw "loose frontend file(s) embedded: $($loose -join ', ')"
    }
    Write-Host ('CAP-6b1 payload proof PASS (listing: bootstrapper present, ' +
        'standalone absent, no fixed tree, no loose frontend, exact 5-file set)')

    # --- 6) abort-probe TEST build: always-fail stub via the documented
    # PWEB_PROV_HELPER hook - proves the fail-closed abort chain in the
    # gates; a test artifact under build/, NEVER under dist/ ----------------
    $StubName = 'pwebwv2provstub.exe'
    @'
program pwebwv2provstub;
{ CAP-6b1 abort-probe stub: stands in for the provisioning helper in
  the TEST-ONLY abort-probe setup build. Always fails with the
  verify_digest exit code so the gates can prove that a helper failure
  aborts the setup before anything is installed. It honors the same
  5th (logfile) argument as the real helper so its verdict lines land
  in the Inno setup log exactly like a genuine refusal would. Never
  shipped. }
{$mode ObjFPC}{$H+}
{$apptype console}
const
  L1 = 'WV2PROV_DIAG abort-probe stub: unconditional failure';
  L2 = 'WV2PROV_RESULT outcome=Failed step=verify_digest';
var
  f: Text;
begin
  writeln(L1);
  writeln(L2);
  if ParamCount >= 5 then
  begin
    Assign(f, ParamStr(5));
    {$I-}
    Rewrite(f);
    {$I+}
    if IOResult = 0 then
    begin
      writeln(f, L1);
      writeln(f, L2);
      Close(f);
    end;
  end;
  ExitCode := 3;
end.
'@ | Set-Content -Encoding ascii build/cap6b1/pwebwv2provstub.pas
    fpc -MObjFPC -Sh -B -FUbuild/cap6b1/fpc -FEbuild/cap6b1/bin `
        build/cap6b1/pwebwv2provstub.pas
    if ($LASTEXITCODE -ne 0) { throw 'abort-probe stub compile failed' }
    Copy-Item "build/cap6b1/bin/$StubName" $Payload/
    $AbortDir = Join-Path $RepoRoot 'build/cap6b1/abort-probe'
    New-Item -ItemType Directory -Force $AbortDir | Out-Null
    & $Iscc "/DPWEB_PAYLOAD_DIR=$Payload" `
        "/DPWEB_WV2_BOOTSTRAPPER=$BootFile" `
        "/DPWEB_WV2_SHA256=$BootSha" `
        "/DPWEB_WV2_SUBJECT=$BootSubject" `
        "/DPWEB_WV2_TIMEOUT_MS=$TimeoutMs" `
        "/DPWEB_PROV_HELPER=$StubName" `
        "/O$AbortDir" '/Fabortprobe' tools/setup/normal.iss
    if ($LASTEXITCODE -ne 0) { throw 'ISCC compile of the abort-probe setup failed' }
    $AbortProbeExe = Join-Path $AbortDir 'abortprobe.exe'
    if (-not (Test-Path $AbortProbeExe)) {
        throw "abort-probe setup missing at $AbortProbeExe"
    }

    # export the exact facts the gates must reuse (single parse point);
    # SetupSize/SetupSha let the CAP-6b4 release orchestrator verify that
    # the artifact it publishes is the one THIS build produced (the same
    # role they already play for the CAP-6b2/6b3 profiles);
    # psd1 single-quoted strings escape embedded quotes by doubling
    $SetupSize = (Get-Item $SetupExe).Length
    $SetupSha = (Get-FileHash -Algorithm SHA256 $SetupExe).Hash.ToLowerInvariant()
    function ConvertTo-Psd1Value([string]$s) { $s -replace "'", "''" }
    @"
@{
    BootFile = '$(ConvertTo-Psd1Value $BootFile)'
    BootSha = '$(ConvertTo-Psd1Value $BootSha)'
    BootSubject = '$(ConvertTo-Psd1Value $BootSubject)'
    StandaloneFile = '$(ConvertTo-Psd1Value $SaFile)'
    SetupExe = '$(ConvertTo-Psd1Value $SetupExe)'
    SetupSize = $SetupSize
    SetupSha = '$(ConvertTo-Psd1Value $SetupSha)'
    AbortProbeExe = '$(ConvertTo-Psd1Value $AbortProbeExe)'
    TimeoutMs = $TimeoutMs
}
"@ | Set-Content -Encoding utf8 build/cap6b1/lockfacts.psd1

    $size = $SetupSize
    $hash = $SetupSha
    Write-Host "CAP-6b1 normal setup built: $SetupExe ($size bytes, sha256 $hash)"
    Write-Host 'CAP6B1_SETUP_BUILD_PASS'
}
finally {
    Pop-Location
}
