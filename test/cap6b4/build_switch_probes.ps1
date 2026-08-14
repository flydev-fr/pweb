# CAP-6b4: the two build-side inputs the profile matrix needs and that
# no earlier shard produces.
#
#   1. THE OFFLINE ABORT PROBE. Matrix row F2 is "fixed -> offline with
#      a failing provisioning helper": setup must exit nonzero BEFORE
#      any file operation, leaving the fixed install byte-identical and
#      its runtime tree intact. CAP-6b1 already builds the equivalent
#      NORMAL probe (row F1) and CAP-6b3 the fixed one (row F3), but no
#      shard builds an offline one - CAP-6b2 deliberately leaned on the
#      CAP-6b1 probe over the shared pwebprovgate.issi. That was right
#      for CAP-6b2's own question and is not enough here: F1 and F2 are
#      distinct switch DIRECTIONS out of a fixed install, and a
#      direction is only proven by the artifact that performs it.
#
#      It is built exactly the ratified way - the always-fail stub
#      substituted through the documented PWEB_PROV_HELPER TEST HOOK,
#      output overridden with /Fabortprobe, landing under build/ and
#      NEVER under dist/. Nothing else may ever override that hook.
#
#   2. build/cap6b4/switchfacts.psd1 - ONE parse point consolidating
#      the three per-shard lockfacts.psd1 files. The matrix chains
#      artifacts from all three shards; without this it would carry
#      three separate Import-PowerShellDataFile calls and three
#      independent ideas of where each artifact lives.
#
# This script installs nothing, provisions nothing and executes no
# Microsoft installer.
#
# Preconditions: all three profile builds have run
# (test/cap6b1/build_normal_setup.ps1, test/cap6b2/build_offline_setup.ps1,
# test/cap6b3/build_fixed_setup.ps1), fpc on PATH.
#
# Usage: pwsh -File test/cap6b4/build_switch_probes.ps1

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Push-Location $RepoRoot
try {
    foreach ($pre in 'build/cap6b1/lockfacts.psd1',
                     'build/cap6b2/lockfacts.psd1',
                     'build/cap6b3/lockfacts.psd1') {
        if (-not (Test-Path $pre)) {
            throw ("missing precondition: $pre -- run the three profile build " +
                'scripts first (test/cap6b1/build_normal_setup.ps1, ' +
                'test/cap6b2/build_offline_setup.ps1, ' +
                'test/cap6b3/build_fixed_setup.ps1)')
        }
    }
    $NormalFacts = Import-PowerShellDataFile (Resolve-Path build/cap6b1/lockfacts.psd1).Path
    $OfflineFacts = Import-PowerShellDataFile (Resolve-Path build/cap6b2/lockfacts.psd1).Path
    $FixedFacts = Import-PowerShellDataFile (Resolve-Path build/cap6b3/lockfacts.psd1).Path

    New-Item -ItemType Directory -Force build/cap6b4 | Out-Null

    # --- 1) the pinned compiler ------------------------------------------------
    pwsh -NoProfile -File tools/get-innosetup.ps1
    if ($LASTEXITCODE -ne 0) { throw 'pinned Inno Setup provisioning failed' }
    $Iscc = Join-Path $RepoRoot 'deps/innosetup/ISCC.exe'
    if (-not (Test-Path $Iscc)) { throw "ISCC.exe missing at $Iscc" }

    # --- 2) the always-fail stub, reused from the ratified CAP-6b1 build ------
    # The stub source and its exit code are CAP-6b1's, compiled by
    # test/cap6b1/build_normal_setup.ps1; reusing that binary is the whole
    # point - the offline probe must differ from the normal one in exactly
    # ONE way, the profile manifest it compiles.
    $StubName = 'pwebwv2provstub.exe'
    $StubSrc = Join-Path $RepoRoot "build/cap6b1/bin/$StubName"
    if (-not (Test-Path $StubSrc)) {
        throw ("missing precondition: $StubSrc -- run " +
            'test/cap6b1/build_normal_setup.ps1 first (it compiles the ratified ' +
            'abort-probe stub)')
    }
    $Payload = Join-Path $RepoRoot 'build/cap6b2/payload'
    if (-not (Test-Path (Join-Path $Payload 'releaseapp.exe'))) {
        throw ("the CAP-6b2 staged payload is missing: $Payload -- run " +
            'test/cap6b2/build_offline_setup.ps1 first')
    }
    # The stub is staged into the directory the REAL offline setup
    # compiles from, because ISCC resolves PWEB_PROV_HELPER inside
    # PWEB_PAYLOAD_DIR. It is removed again in the finally below: leaving
    # an always-fail helper sitting in a production staging directory is
    # exactly the kind of thing a later hand-run ISCC would embed by
    # accident.
    $StagedStub = Join-Path $Payload $StubName
    Copy-Item $StubSrc $StagedStub -Force

    # --- 3) the offline abort probe -------------------------------------------
    # the lock facts come from the CAP-6b2 build's own export, so the probe
    # and the real offline setup are compiled from identical defines except
    # for the documented helper hook
    $SaFile = $OfflineFacts.StandaloneFile
    $SaSha = $OfflineFacts.StandaloneSha
    $SaSubject = $OfflineFacts.StandaloneSubject
    $TimeoutMs = $OfflineFacts.TimeoutMs
    foreach ($pair in @{ StandaloneFile = $SaFile; StandaloneSha = $SaSha;
        StandaloneSubject = $SaSubject; TimeoutMs = $TimeoutMs }.GetEnumerator()) {
        if (-not $pair.Value) {
            throw "build/cap6b2/lockfacts.psd1 carries no $($pair.Key) - rebuild the offline profile"
        }
    }
    $AbortDir = Join-Path $RepoRoot 'build/cap6b4/abort-probe-offline'
    New-Item -ItemType Directory -Force $AbortDir | Out-Null
    # a stale output can still be HELD by Inno's respawned second stage
    # (abortprobe.tmp) if an earlier run was killed rather than allowed to
    # finish; ISCC would then fail to overwrite it with an opaque error.
    # Clear it here and say so plainly (the ratified CAP-6b3 idiom).
    $OfflineAbortProbe = Join-Path $AbortDir 'abortprobe.exe'
    if (Test-Path $OfflineAbortProbe) {
        try {
            Remove-Item -Force -LiteralPath $OfflineAbortProbe -ErrorAction Stop
        }
        catch {
            throw ("cannot replace the stale offline abort probe $OfflineAbortProbe - " +
                'a previous abort-probe run is probably still alive (look for ' +
                "abortprobe.tmp): $($_.Exception.Message)")
        }
    }
    $ListingFile = Join-Path $RepoRoot 'build/cap6b4/iscc-offline-abort.log'
    & $Iscc "/DPWEB_PAYLOAD_DIR=$Payload" `
        "/DPWEB_WV2_STANDALONE=$SaFile" `
        "/DPWEB_WV2_SHA256=$SaSha" `
        "/DPWEB_WV2_SUBJECT=$SaSubject" `
        "/DPWEB_WV2_TIMEOUT_MS=$TimeoutMs" `
        "/DPWEB_PROV_HELPER=$StubName" `
        "/O$AbortDir" '/Fabortprobe' tools/setup/offline.iss 2>&1 |
        Tee-Object -FilePath $ListingFile | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # never swallow this: a discarded listing turns a one-line ISCC
        # diagnostic into a blind rebuild
        Get-Content $ListingFile | Select-Object -Last 15 | Write-Host
        throw 'ISCC compile of the offline abort-probe setup failed'
    }
    if (-not (Test-Path $OfflineAbortProbe)) {
        throw "offline abort-probe setup missing at $OfflineAbortProbe"
    }
    # the probe must carry the STUB, not the real helper: a probe that
    # silently embedded the genuine helper would PASS its own leg while
    # proving nothing
    $listing = Get-Content $ListingFile -Raw
    if ($listing -notmatch [regex]::Escape($StubName)) {
        throw "the offline abort probe does not embed the always-fail stub $StubName"
    }
    if ($listing -match 'pwebwv2prov\.exe') {
        throw ('the offline abort probe embeds the REAL provisioning helper - the ' +
            'PWEB_PROV_HELPER hook did not take effect')
    }
    Write-Host ("CAP-6b4 offline abort probe built: $OfflineAbortProbe " +
        "($((Get-Item $OfflineAbortProbe).Length) bytes, stub $StubName embedded)")

    # --- 4) the consolidated facts --------------------------------------------
    # every artifact the matrix chains, resolved and existence-checked ONCE
    $Artifacts = [ordered]@{
        NormalSetup        = $NormalFacts.SetupExe
        OfflineSetup       = $OfflineFacts.SetupExe
        FixedSetup         = $FixedFacts.SetupExe
        NormalAbortProbe   = $NormalFacts.AbortProbeExe
        OfflineAbortProbe  = $OfflineAbortProbe
        FixedAbortProbe    = $FixedFacts.AbortProbeExe
        FixedHelper        = $FixedFacts.Helper
        TreeManifest       = $FixedFacts.ManifestFile
        ProvHelper         = (Join-Path $RepoRoot 'build/cap6b1/bin/pwebwv2prov.exe')
    }
    foreach ($k in $Artifacts.Keys) {
        if (-not $Artifacts[$k]) { throw "consolidated facts: $k resolved to nothing" }
        if (-not (Test-Path -LiteralPath $Artifacts[$k])) {
            throw "consolidated facts: $k missing on disk: $($Artifacts[$k])"
        }
    }
    # no shipped artifact may be the appcompat-shimmed name
    foreach ($k in 'NormalSetup', 'OfflineSetup', 'FixedSetup') {
        $leaf = Split-Path -Leaf $Artifacts[$k]
        if ($leaf -ieq 'setup.exe') {
            throw "$k is still named setup.exe - the CAP-6b4 rename did not take"
        }
    }

    # every NUMERIC fact is interpolated unquoted, so a null upstream
    # value would emit a bare `Key =` and the matrix would die on an
    # opaque psd1 parse error instead of naming the missing input
    $Numerics = [ordered]@{
        TreeFiles      = $FixedFacts.TreeFiles
        TreeBytes      = $FixedFacts.TreeBytes
        StandaloneSize = $OfflineFacts.StandaloneSize
    }
    foreach ($k in $Numerics.Keys) {
        $v = $Numerics[$k]
        if (($null -eq $v) -or ("$v" -notmatch '^\d+$') -or ([long]$v -le 0)) {
            throw ("the exported lock facts carry no usable $k (got '$v') - " +
                'rebuild the profile that exports it before consolidating')
        }
    }
    # and every STRING fact the matrix reads must be non-empty for the
    # same reason
    foreach ($k in 'TreeName', 'FixedVersion', 'FixedSubject', 'RuntimeDir') {
        if (-not $FixedFacts[$k]) {
            throw "build/cap6b3/lockfacts.psd1 carries no $k - rebuild the fixed profile"
        }
    }
    if (-not $NormalFacts.BootFile) {
        throw 'build/cap6b1/lockfacts.psd1 carries no BootFile - rebuild the normal profile'
    }

    function ConvertTo-Psd1Value([string]$s) { $s -replace "'", "''" }
    @"
@{
    NormalSetup = '$(ConvertTo-Psd1Value $Artifacts.NormalSetup)'
    OfflineSetup = '$(ConvertTo-Psd1Value $Artifacts.OfflineSetup)'
    FixedSetup = '$(ConvertTo-Psd1Value $Artifacts.FixedSetup)'
    NormalAbortProbe = '$(ConvertTo-Psd1Value $Artifacts.NormalAbortProbe)'
    OfflineAbortProbe = '$(ConvertTo-Psd1Value $Artifacts.OfflineAbortProbe)'
    FixedAbortProbe = '$(ConvertTo-Psd1Value $Artifacts.FixedAbortProbe)'
    FixedHelper = '$(ConvertTo-Psd1Value $Artifacts.FixedHelper)'
    TreeManifest = '$(ConvertTo-Psd1Value $Artifacts.TreeManifest)'
    TreeName = '$(ConvertTo-Psd1Value $FixedFacts.TreeName)'
    FixedVersion = '$(ConvertTo-Psd1Value $FixedFacts.FixedVersion)'
    FixedSubject = '$(ConvertTo-Psd1Value $FixedFacts.FixedSubject)'
    RuntimeDir = '$(ConvertTo-Psd1Value $FixedFacts.RuntimeDir)'
    TreeFiles = $($Numerics.TreeFiles)
    TreeBytes = $($Numerics.TreeBytes)
    BootFile = '$(ConvertTo-Psd1Value $NormalFacts.BootFile)'
    StandaloneFile = '$(ConvertTo-Psd1Value $OfflineFacts.StandaloneFile)'
    StandaloneSize = $($Numerics.StandaloneSize)
    ProvHelper = '$(ConvertTo-Psd1Value $Artifacts.ProvHelper)'
    StubName = '$(ConvertTo-Psd1Value $StubName)'
}
"@ | Set-Content -Encoding utf8 build/cap6b4/switchfacts.psd1

    # it must round-trip: a psd1 the matrix cannot parse is a broken gate
    $rt = Import-PowerShellDataFile (Resolve-Path build/cap6b4/switchfacts.psd1).Path
    foreach ($k in 'NormalSetup', 'OfflineSetup', 'FixedSetup', 'NormalAbortProbe',
        'OfflineAbortProbe', 'FixedAbortProbe', 'TreeName', 'FixedVersion') {
        if (-not $rt[$k]) { throw "switchfacts.psd1 did not round-trip key $k" }
    }
    Write-Host 'CAP-6b4 consolidated facts written: build/cap6b4/switchfacts.psd1'
    Write-Host 'CAP6B4_SWITCH_PROBES_PASS'
}
finally {
    # the always-fail stub never outlives this script inside the CAP-6b2
    # production staging directory, on any path
    if (($null -ne $StagedStub) -and (Test-Path -LiteralPath $StagedStub)) {
        Remove-Item -LiteralPath $StagedStub -Force -ErrorAction SilentlyContinue
    }
    Pop-Location
}
