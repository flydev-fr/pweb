# CAP-6b2: builds dist/windows/offline/setup.exe - the OFFLINE-profile
# per-user installer embedding the lock-verified x64 Evergreen
# STANDALONE Installer (webview2-runtime.lock artifact
# evergreen-standalone-x64), so a WebView2-less machine WITHOUT
# network provisions its runtime from the embedded payload alone.
#
#   1. provisions the pinned Inno Setup 6 compiler (innosetup.lock)
#   2. acquires the LOCKED standalone through webview2-runtime.lock
#      (sha256 + Authenticode subject verified; upstream drift fails
#      the build and deletes the download; NOTHING is executed here).
#      A previously verified local copy is reused ONLY after it
#      re-passes sha256 + size + Authenticode against the lock at THIS
#      build moment - the ~210 MB fetch is skipped, the verification
#      never is
#   3. compiles the pwebwv2prov setup helper (frozen CAP-6b0 policy
#      reused through pweb.platform.webview2.provision; byte-identical
#      source to the CAP-6b1 normal profile)
#   4. stages the payload: the unchanged CAP-6 release triple from
#      build/cap6/release + standalone + helper, re-verifying the
#      staged standalone against the lock digest (defense in depth)
#   5. compiles tools/setup/offline.iss (which consumes the shared
#      pwebprovgate.issi include - the SAME gate the CAP-6b1 gates
#      prove) with every define derived from the lock at THIS build
#      moment; the bounded timeout is parsed from
#      PWEB_WV2_INSTALL_TIMEOUT_MS in the provisioning unit (single
#      source, house 1587-cross-check idiom)
#   6. payload proof from the captured ISCC compile listing: the
#      embedded file set is EXACTLY the release triple + standalone
#      (by locked filename) + helper - the Bootstrapper is absent, no
#      Fixed Runtime tree, no loose frontend files - and the final
#      setup.exe size is recorded and must be >= the standalone size
#      (the payload is already compressed; there is no
#      size-optimization target)
#
# The lock facts used are exported to build/cap6b2/lockfacts.psd1 so
# the gate scripts consume the exact same parse.
#
# Preconditions: build/cap6/release assembled by test/cap6/run_cap6_gates.ps1
# (which needs build_cap6.ps1 + the React dist), fpc on PATH.
#
# Usage: pwsh -File test/cap6b2/build_offline_setup.ps1

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

    # --- lock facts: authoritative validation first (zero network), then
    # one strict, targeted parse of the two ratified entries - the
    # standalone (to embed) and the bootstrapper (whose ABSENCE from the
    # offline payload is asserted below) -----------------------------------
    pwsh -NoProfile -File tools/get-webview2-runtime.ps1 -Validate
    if ($LASTEXITCODE -ne 0) { throw 'webview2-runtime.lock validation failed' }
    $lockLines = Get-Content (Join-Path $RepoRoot 'webview2-runtime.lock')
    $saFacts = @{}
    $bsFacts = @{}
    $section = ''
    foreach ($raw in $lockLines) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '=') {
            # belt-and-braces: the authoritative -Validate above already
            # refused malformed locks, but this targeted re-parse must
            # never crash on nulls either - name the offending line
            throw "webview2-runtime.lock: malformed non-comment line in targeted re-parse: $line"
        }
        $k, $v = $line -split '=', 2
        $k = $k.Trim(); $v = $v.Trim()
        if ($k -ceq 'artifact') { $section = $v; continue }
        if ($section -ceq 'evergreen-standalone-x64') { $saFacts[$k] = $v }
        elseif ($section -ceq 'evergreen-bootstrapper') { $bsFacts[$k] = $v }
    }
    foreach ($key in 'filename', 'size', 'sha256', 'authenticode-subject') {
        if (-not $saFacts[$key]) {
            throw "webview2-runtime.lock: evergreen-standalone-x64 is missing '$key'"
        }
    }
    if (-not $bsFacts['filename']) {
        throw "webview2-runtime.lock: evergreen-bootstrapper is missing 'filename'"
    }
    $SaFile = $saFacts['filename']
    $SaSize = [long]$saFacts['size']
    $SaSha = $saFacts['sha256']
    $SaSubject = $saFacts['authenticode-subject']
    $BootFile = $bsFacts['filename']

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

    # --- 2) locked standalone (verified acquire, never executed) ---------------
    $SaPath = Join-Path $RepoRoot "deps/webview2-runtime/$SaFile"
    $reuse = $false
    if (Test-Path $SaPath) {
        # reuse is allowed ONLY after the full re-verification the fetch
        # would perform: sha256 first, then size, then Authenticode
        # status Valid + exact leaf subject - any miss deletes the copy
        # and falls through to a fresh locked fetch
        $localSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $SaPath).Hash.ToLowerInvariant()
        $localSize = (Get-Item -LiteralPath $SaPath).Length
        $sig = Get-AuthenticodeSignature -FilePath $SaPath
        $localSubject = 'unsigned'
        if ($null -ne $sig.SignerCertificate) {
            $localSubject = $sig.SignerCertificate.Subject
        }
        if (($localSha -ceq $SaSha) -and ($localSize -eq $SaSize) -and
            ("$($sig.Status)" -ceq 'Valid') -and ($localSubject -ceq $SaSubject)) {
            Write-Host ("locked standalone reused after full re-verification: " +
                "$SaPath ($localSize bytes, sha256 + authenticode OK)")
            $reuse = $true
        }
        else {
            Write-Host ("local standalone copy failed re-verification " +
                "(sha256=$localSha size=$localSize status=$($sig.Status)) - " +
                'deleted; fetching the locked artifact')
            Remove-Item -Force -LiteralPath $SaPath
        }
    }
    if (-not $reuse) {
        pwsh -NoProfile -File tools/get-webview2-runtime.ps1 `
            -Artifact evergreen-standalone-x64
        if ($LASTEXITCODE -ne 0) {
            throw 'locked standalone fetch-verify failed (upstream drift? see error above)'
        }
        if (-not (Test-Path $SaPath)) { throw "verified standalone missing: $SaPath" }
    }

    # --- 3) compile the setup helper -------------------------------------------
    New-Item -ItemType Directory -Force build/cap6b2/fpc, build/cap6b2/bin |
        Out-Null
    fpc -MObjFPC -Sh -B -FUbuild/cap6b2/fpc -FEbuild/cap6b2/bin `
        -Fusrc/platform/windows `
        -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib `
        -Fudeps/mormot2/src/crypt `
        tools/setup/pwebwv2prov.pas
    if ($LASTEXITCODE -ne 0) { throw 'pwebwv2prov helper compile failed' }

    # --- 4) stage the payload ---------------------------------------------------
    # the staging dir is wiped WHOLE (subdirectories and hidden files
    # included) so nothing an aborted earlier run left behind can ride
    # into the embedded payload
    if (Test-Path build/cap6b2/payload) {
        Remove-Item -Recurse -Force build/cap6b2/payload
    }
    New-Item -ItemType Directory -Force build/cap6b2/payload | Out-Null
    $Payload = (Resolve-Path build/cap6b2/payload).Path
    Copy-Item build/cap6/release/releaseapp.exe $Payload/
    Copy-Item build/cap6/release/app.pwb $Payload/
    Copy-Item build/cap6/release/webview.dll $Payload/
    Copy-Item $SaPath $Payload/
    Copy-Item build/cap6b2/bin/pwebwv2prov.exe $Payload/
    # defense in depth: what gets EMBEDDED equals the ratified bytes
    $staged = (Get-FileHash -Algorithm SHA256 `
        (Join-Path $Payload $SaFile)).Hash.ToLowerInvariant()
    if ($staged -cne $SaSha) {
        Remove-Item -Force (Join-Path $Payload $SaFile)
        throw "staged standalone sha256 drifted: expected $SaSha, got $staged"
    }

    # --- 5) compile the setup, capturing the compile listing --------------------
    $DistDir = Join-Path $RepoRoot 'dist/windows/offline'
    New-Item -ItemType Directory -Force $DistDir | Out-Null
    $ListingFile = Join-Path $RepoRoot 'build/cap6b2/iscc-offline.log'
    & $Iscc "/DPWEB_PAYLOAD_DIR=$Payload" `
        "/DPWEB_WV2_STANDALONE=$SaFile" `
        "/DPWEB_WV2_SHA256=$SaSha" `
        "/DPWEB_WV2_SUBJECT=$SaSubject" `
        "/DPWEB_WV2_TIMEOUT_MS=$TimeoutMs" `
        "/O$DistDir" '/Fsetup' tools/setup/offline.iss 2>&1 |
        Tee-Object -FilePath $ListingFile
    if ($LASTEXITCODE -ne 0) { throw 'ISCC compile of offline.iss failed' }
    $SetupExe = Join-Path $DistDir 'setup.exe'
    if (-not (Test-Path $SetupExe)) { throw "setup.exe missing at $SetupExe" }

    # --- 6) payload proof from the compile listing ------------------------------
    # the listing is authoritative evidence of what ISCC actually
    # embedded; every assertion below is against IT, not the staging dir
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
    $expectedSet = @('app.pwb', $SaFile, 'pwebwv2prov.exe', 'releaseapp.exe',
        'webview.dll') | Sort-Object
    if (($compressed -join ',') -cne ($expectedSet -join ',')) {
        throw ("embedded payload set drifted: listing shows [$($compressed -join ', ')], " +
            "expected exactly [$($expectedSet -join ', ')]")
    }
    if ($compressed -cnotcontains $SaFile) {
        throw "standalone '$SaFile' missing from the embedded payload listing"
    }
    if ($listing -match [regex]::Escape($BootFile)) {
        throw ("OFFLINE INVARIANT BROKEN: the Bootstrapper '$BootFile' appears " +
            'in the offline compile listing')
    }
    if ($listing -match '(?i)msedgewebview2') {
        throw 'OFFLINE INVARIANT BROKEN: a Fixed Runtime tree file appears in the listing'
    }
    $loose = @($compressed | Where-Object { $_ -match '\.(html|css|js|map|json)$' })
    if ($loose) {
        throw "loose frontend file(s) embedded: $($loose -join ', ')"
    }
    Write-Host ('CAP-6b2 payload proof PASS (listing: standalone present, ' +
        'bootstrapper absent, no fixed tree, no loose frontend, exact 5-file set)')

    # size record: the payload is already compressed, so the setup can
    # never be smaller than the standalone it embeds - a smaller output
    # means the wrong bytes went in
    $SetupSize = (Get-Item $SetupExe).Length
    if ($SetupSize -lt $SaSize) {
        throw ("setup.exe ($SetupSize bytes) is SMALLER than the embedded " +
            "standalone ($SaSize bytes) - the payload cannot be complete")
    }

    # export the exact facts the gates must reuse (single parse point);
    # SetupSha lets the offline clean-machine gate verify the very
    # setup.exe it is about to execute against THIS build's bytes;
    # psd1 single-quoted strings escape embedded quotes by doubling
    $SetupSha = (Get-FileHash -Algorithm SHA256 $SetupExe).Hash.ToLowerInvariant()
    function ConvertTo-Psd1Value([string]$s) { $s -replace "'", "''" }
    @"
@{
    StandaloneFile = '$(ConvertTo-Psd1Value $SaFile)'
    StandaloneSha = '$(ConvertTo-Psd1Value $SaSha)'
    StandaloneSubject = '$(ConvertTo-Psd1Value $SaSubject)'
    StandaloneSize = $SaSize
    BootFile = '$(ConvertTo-Psd1Value $BootFile)'
    SetupExe = '$(ConvertTo-Psd1Value $SetupExe)'
    SetupSize = $SetupSize
    SetupSha = '$(ConvertTo-Psd1Value $SetupSha)'
    TimeoutMs = $TimeoutMs
}
"@ | Set-Content -Encoding utf8 build/cap6b2/lockfacts.psd1

    Write-Host "CAP-6b2 offline setup built: $SetupExe ($SetupSize bytes, sha256 $SetupSha)"
    Write-Host 'CAP6B2_SETUP_BUILD_PASS'
}
finally {
    Pop-Location
}
