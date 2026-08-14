# CAP-6b3: builds
# dist/windows/fixed-runtime/PWebRelease-FixedRuntime-Setup.exe - the
# FIXED-RUNTIME-profile per-user installer that deploys the
# lock-verified x64 WebView2 Fixed Version Runtime tree
# (webview2-runtime.lock artifact webview2-fixed-runtime-x64) plus the
# pinned WebView2 SDK's WebView2Loader.dll as ordinary application
# content, and runs NO provisioning of any kind.
#
# The artifact basename is authored in tools/setup/fixed.iss
# (PWEB_SETUP_BASENAME) and PARSED here, never passed with /F: the
# manifest stays the single source of the name, and no artifact this
# repository ships is called setup.exe (CAP-6b4).
#
#   1. provisions the pinned Inno Setup 6 compiler (innosetup.lock)
#   2. cross-checks the Pascal pin constants against the lock (the
#      house 1587-cross-check idiom): PWEB_WV2_FIXED_VERSION in
#      src/platform/windows/pweb.platform.webview2.fixed.pas must equal
#      the lock's `version`, and the compiled helper's --pin output
#      must agree with both - so the tree folder name, the loader name
#      and the manifest tag can never drift from the ratified pin
#   3. acquires the LOCKED ~290 MB cabinet through
#      webview2-runtime.lock (sha256 + Authenticode subject verified;
#      upstream drift fails the build and deletes the download).
#      NOTHING is ever executed: this artifact is not an installer at
#      all, it is a cabinet whose extracted tree IS the runtime. A
#      previously verified local copy is reused ONLY after it re-passes
#      sha256 + size + Authenticode against the lock at THIS build
#      moment - the fetch is skipped, the verification never is
#   4. compiles the fixed-runtime release host
#      (-dPWEB_FIXED_RUNTIME, inside a re-applied CAP-3U window,
#      restored and re-verified pristine afterwards) and the compiled
#      pwebwv2fixed helper
#   5. extracts the cabinet with `expand -F:*` STRAIGHT INTO the
#      staging runtime folder, proves it yielded exactly the one
#      ratified tree folder, drops the pinned-SDK loader beside it
#      (Authenticode-verified against the same ratified subject - the
#      Fixed Runtime package ships no loader), then validates the
#      staged tree through the native helper and writes its
#      deterministic manifest
#   6. compiles tools/setup/fixed.iss (which consumes the shared
#      tools/setup/pwebappsetup.issi identity include - the SAME
#      identity the CAP-6b1/6b2 gates prove) with the profile-scoped
#      compression override, capturing the compile listing
#   7. payload proof from the captured ISCC compile listing, keyed on
#      FULL RELATIVE PATHS (never collapsed basenames - a browser tree
#      is full of repeated names): the embedded set is EXACTLY the
#      release triple + the ACL helper + every staged runtime file,
#      the Evergreen Bootstrapper and Standalone Installer are BOTH
#      absent, and loose frontend files are banned OUTSIDE the runtime
#      subtree (inside it, .js/.json are legitimate browser resources)
#
# The lock facts used are exported to build/cap6b3/lockfacts.psd1 so
# the gate scripts consume the exact same parse.
#
# Preconditions: build/cap6/release assembled by test/cap6/run_cap6_gates.ps1
# (which needs build_cap6.ps1 + the React dist), fpc on PATH.
#
# Usage: pwsh -File test/cap6b3/build_fixed_setup.ps1

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Push-Location $RepoRoot
try {
    foreach ($pre in 'build/cap6/release/app.pwb',
                     'build/cap6/release/webview.dll') {
        if (-not (Test-Path $pre)) {
            throw ("missing precondition: $pre -- run " +
                'test/cap6/run_cap6_gates.ps1 first (it assembles the release dir)')
        }
    }
    # the pinned WebView2 SDK loader comes from the SAME cmake build tree
    # webview.lock pins by extracted-tree sha256 (tools/build-webview-dll.ps1)
    $LoaderSrc = Join-Path $RepoRoot ('build/webview-build-cap4w/_deps/' +
        'microsoft_web_webview2-src/build/native/x64/WebView2Loader.dll')
    if (-not (Test-Path $LoaderSrc)) {
        throw ("missing precondition: $LoaderSrc -- run " +
            'tools/build-webview-dll.ps1 first (it fetches and hash-verifies ' +
            'the pinned WebView2 SDK tree that carries the loader)')
    }

    # --- 1) pinned Inno Setup 6 ------------------------------------------------
    pwsh -NoProfile -File tools/get-innosetup.ps1
    if ($LASTEXITCODE -ne 0) { throw 'pinned Inno Setup provisioning failed' }
    $Iscc = Join-Path $RepoRoot 'deps/innosetup/ISCC.exe'
    if (-not (Test-Path $Iscc)) { throw "ISCC.exe missing at $Iscc" }

    # --- lock facts: authoritative validation first (zero network), then
    # one strict, targeted parse of the three ratified entries - the fixed
    # runtime (to embed) and both Evergreen installers (whose ABSENCE from
    # the fixed payload is asserted below) ---------------------------------
    pwsh -NoProfile -File tools/get-webview2-runtime.ps1 -Validate
    if ($LASTEXITCODE -ne 0) { throw 'webview2-runtime.lock validation failed' }
    $lockLines = Get-Content (Join-Path $RepoRoot 'webview2-runtime.lock')
    $fxFacts = @{}
    $bsFacts = @{}
    $saFacts = @{}
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
        if ($section -ceq 'webview2-fixed-runtime-x64') { $fxFacts[$k] = $v }
        elseif ($section -ceq 'evergreen-bootstrapper') { $bsFacts[$k] = $v }
        elseif ($section -ceq 'evergreen-standalone-x64') { $saFacts[$k] = $v }
    }
    foreach ($key in 'filename', 'size', 'sha256', 'authenticode-subject',
        'version', 'kind') {
        if (-not $fxFacts[$key]) {
            throw "webview2-runtime.lock: webview2-fixed-runtime-x64 is missing '$key'"
        }
    }
    if ($fxFacts['kind'] -cne 'fixed') {
        throw "webview2-runtime.lock: webview2-fixed-runtime-x64 kind is '$($fxFacts['kind'])', expected fixed"
    }
    foreach ($pair in @(@{n = 'evergreen-bootstrapper'; f = $bsFacts },
                        @{n = 'evergreen-standalone-x64'; f = $saFacts })) {
        if (-not $pair.f['filename']) {
            throw "webview2-runtime.lock: $($pair.n) is missing 'filename'"
        }
    }
    $FxFile = $fxFacts['filename']
    $FxSize = [long]$fxFacts['size']
    $FxSha = $fxFacts['sha256']
    $FxSubject = $fxFacts['authenticode-subject']
    $FxVersion = $fxFacts['version']
    $BootFile = $bsFacts['filename']
    $SaFile = $saFacts['filename']

    # --- 2) the Pascal pin is the single source: cross-check it ---------------
    $fixedUnit = Get-Content (Join-Path $RepoRoot `
        'src/platform/windows/pweb.platform.webview2.fixed.pas') -Raw
    if ($fixedUnit -notmatch "PWEB_WV2_FIXED_VERSION\s*=\s*'([0-9.]+)'\s*;") {
        throw 'PWEB_WV2_FIXED_VERSION constant not found in the fixed-runtime unit'
    }
    $PasVersion = $Matches[1]
    if ($PasVersion -cne $FxVersion) {
        throw ("fixed-runtime pin drift: the lock says $FxVersion, " +
            "pweb.platform.webview2.fixed.pas says $PasVersion")
    }
    # the ratified cabinet name embeds the same version: a lock entry whose
    # filename disagreed with its own version key would extract a tree the
    # unit could never find
    if ($FxFile -cne "Microsoft.WebView2.FixedVersionRuntime.$FxVersion.x64.cab") {
        throw ("lock filename '$FxFile' does not match the pinned version " +
            "$FxVersion - refusing to build on an incoherent pin")
    }

    # --- 3) locked cabinet (verified acquire, NEVER executed) -----------------
    $FxPath = Join-Path $RepoRoot "deps/webview2-runtime/$FxFile"
    $reuse = $false
    if (Test-Path $FxPath) {
        # reuse is allowed ONLY after the full re-verification the fetch
        # would perform: sha256 first, then size, then Authenticode
        # status Valid + exact leaf subject - any miss deletes the copy
        # and falls through to a fresh locked fetch
        $localSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $FxPath).Hash.ToLowerInvariant()
        $localSize = (Get-Item -LiteralPath $FxPath).Length
        $sig = Get-AuthenticodeSignature -FilePath $FxPath
        $localSubject = 'unsigned'
        if ($null -ne $sig.SignerCertificate) {
            $localSubject = $sig.SignerCertificate.Subject
        }
        if (($localSha -ceq $FxSha) -and ($localSize -eq $FxSize) -and
            ("$($sig.Status)" -ceq 'Valid') -and ($localSubject -ceq $FxSubject)) {
            Write-Host ("locked fixed runtime reused after full re-verification: " +
                "$FxPath ($localSize bytes, sha256 + authenticode OK)")
            $reuse = $true
        }
        else {
            Write-Host ("local fixed-runtime copy failed re-verification " +
                "(sha256=$localSha size=$localSize status=$($sig.Status)) - " +
                'deleted; fetching the locked artifact')
            Remove-Item -Force -LiteralPath $FxPath
        }
    }
    if (-not $reuse) {
        pwsh -NoProfile -File tools/get-webview2-runtime.ps1 `
            -Artifact webview2-fixed-runtime-x64
        if ($LASTEXITCODE -ne 0) {
            throw 'locked fixed-runtime fetch-verify failed (upstream drift? see error above)'
        }
        if (-not (Test-Path $FxPath)) { throw "verified fixed runtime missing: $FxPath" }
    }

    # --- 4a) the compiled native helper ---------------------------------------
    New-Item -ItemType Directory -Force build/cap6b3/fpc, build/cap6b3/bin |
        Out-Null
    fpc -MObjFPC -Sh -B -FUbuild/cap6b3/fpc -FEbuild/cap6b3/bin `
        -Fusrc/platform/windows `
        -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib `
        -Fudeps/mormot2/src/crypt `
        tools/setup/pwebwv2fixed.pas
    if ($LASTEXITCODE -ne 0) { throw 'pwebwv2fixed helper compile failed' }
    $Helper = (Resolve-Path build/cap6b3/bin/pwebwv2fixed.exe).Path

    # the helper is compiled from the same unit: its --pin output must
    # agree with the lock, so a rename of the tree folder convention or
    # the manifest tag breaks THIS build, never a runtime gate
    $pin = & $Helper --pin 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "helper --pin failed: $pin" }
    $ExpectedTree = "Microsoft.WebView2.FixedVersionRuntime.$FxVersion.x64"
    # WV2FIXED_PIN carries COMPILED-IN constants under treename=; the
    # observed-tree line (WV2FIXED_VALIDATED, treedir=) is deliberately
    # a different prefix with different keys, so this grep can never be
    # satisfied by an observation of some other tree
    if ($pin -notmatch '(?m)^WV2FIXED_PIN ') {
        throw "helper --pin emitted no WV2FIXED_PIN line: $pin"
    }
    if ($pin -notmatch [regex]::Escape("version=$FxVersion treename=$ExpectedTree ")) {
        throw ("helper --pin disagrees with the lock (expected version=$FxVersion " +
            "treename=$ExpectedTree): $pin")
    }
    if ($pin -notmatch 'loader=WebView2Loader\.dll') {
        throw "helper --pin does not name the bundled loader: $pin"
    }
    $ManifestTag = ''
    if ($pin -match 'manifest=(.+?)\r?\n') { $ManifestTag = $Matches[1].Trim() }
    if ($ManifestTag -eq '') { throw "helper --pin printed no manifest tag: $pin" }
    Write-Host ("CAP-6b3 pin cross-check PASS (lock = Pascal constant = helper: " +
        "$FxVersion / $ExpectedTree)")

    # --- 4b) the FIXED-RUNTIME release host, inside the CAP-3U window ---------
    New-Item -ItemType Directory -Force build/cap6b3/host-fpc | Out-Null
    try {
        pwsh -NoProfile -File tools/patch-cap3u.ps1
        if ($LASTEXITCODE -ne 0) { throw 'CAP-6b3 CAP-3U re-apply failed' }
        fpc -MObjFPC -Sh -B -Xm -dPWEB_CALLMETHOD_UNWIND_PROBE `
            -dPWEB_FIXED_RUNTIME `
            -FUbuild/cap6b3/host-fpc -FEbuild/cap6b3/bin `
            -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview `
            -Fusrc/assets -Fusrc/platform/windows `
            -Fideps/mormot2/src -Fudeps/mormot2/src/core `
            -Fudeps/mormot2/src/lib -Fudeps/mormot2/src/crypt `
            -Fudeps/mormot2/src/net -Fudeps/mormot2/src/db `
            -Fudeps/mormot2/src/orm -Fudeps/mormot2/src/rest `
            -Fudeps/mormot2/src/soa `
            -Fldeps/mormot2/static/x86_64-win64 `
            examples/08-release/releaseapp.pas
        if ($LASTEXITCODE -ne 0) { throw 'CAP-6b3 fixed release host compile failed' }
    }
    finally {
        $restoreFailures = @()
        foreach ($attempt in 1..2) {
            pwsh -NoProfile -File tools/patch-cap3u.ps1 -Restore
            if ($LASTEXITCODE -ne 0) { $restoreFailures += $attempt }
        }
        if ($restoreFailures) {
            throw "CAP-6b3 CAP-3U restore attempts failed: $($restoreFailures -join ', ')"
        }
    }
    git -C deps/mormot2 diff --exit-code HEAD -- src/core/mormot.core.interfaces.pas
    if ($LASTEXITCODE -ne 0) { throw 'CAP-3U source is not pristine after CAP-6b3 restore' }
    if (Test-Path deps/mormot2/src/core/x64callmethod.obj) {
        throw 'CAP-3U object survived CAP-6b3 restore'
    }

    # --- 5) extract the cabinet straight into the staging runtime folder ------
    # the staging dir is wiped WHOLE (subdirectories and hidden files
    # included) so nothing an aborted earlier run left behind can ride
    # into the embedded payload
    $RuntimeDir = Join-Path $RepoRoot 'build/cap6b3/runtime'
    if (Test-Path $RuntimeDir) { Remove-Item -Recurse -Force $RuntimeDir }
    New-Item -ItemType Directory -Force $RuntimeDir | Out-Null
    Write-Host "expanding $FxFile into $RuntimeDir (this takes a while: ~690 MB)"
    $expandOut = & expand.exe -F:* $FxPath $RuntimeDir 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "expand of the locked cabinet failed: $expandOut"
    }
    $topLevel = @(Get-ChildItem $RuntimeDir -Force | ForEach-Object Name)
    if (($topLevel -join ',') -cne $ExpectedTree) {
        throw ("the cabinet did not extract to exactly one folder named " +
            "'$ExpectedTree': [$($topLevel -join ', ')]")
    }
    $TreeDir = Join-Path $RuntimeDir $ExpectedTree
    # -Force everywhere: ISCC's recursesubdirs embeds hidden files, so a
    # hidden entry must be COUNTED here or the payload-set proof below
    # fails with an opaque "drifted" message instead of a real defect
    $treeFiles = @(Get-ChildItem $TreeDir -Recurse -File -Force)
    $treeBytes = ($treeFiles | Measure-Object -Property Length -Sum).Sum
    Write-Host ("extracted tree: $($treeFiles.Count) file(s), $treeBytes byte(s)")
    foreach ($required in 'msedgewebview2.exe', 'msedge.dll',
                          'EBWebView\x64\EmbeddedBrowserWebView.dll') {
        if (-not (Test-Path (Join-Path $TreeDir $required))) {
            throw "extracted tree is incomplete: $required missing"
        }
    }
    # every versioned binary must BE the pinned version, read through
    # the SAME native primitive the installed app uses: the numeric
    # VS_FIXEDFILEINFO, never the string resource (they can legitimately
    # differ, and a build that asserted the string while the app read
    # the number could ship a setup every install refuses at step=version)
    foreach ($versioned in 'msedgewebview2.exe', 'msedge.dll',
                           'EBWebView\x64\EmbeddedBrowserWebView.dll') {
        $vp = Join-Path $TreeDir $versioned
        $vout = & $Helper --file-version $vp 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "native file-version read failed for ${versioned}: $vout"
        }
        if ($vout -cnotmatch "WV2FIXED_FILEVERSION file=.+ version=$([regex]::Escape($FxVersion))\r?\n") {
            throw ("extracted $versioned is not the pinned $FxVersion " +
                "(native VS_FIXEDFILEINFO read): $vout")
        }
    }
    Write-Host ("CAP-6b3 tree version PASS (3 binaries at $FxVersion by the " +
        'native numeric reader the app itself uses)')
    # the five critical binaries carry the exact ratified Microsoft leaf
    # subject; the eleven non-critical redistributables legitimately carry
    # the second Microsoft subject and are NOT enforced on that axis
    foreach ($critical in 'msedgewebview2.exe', 'msedge.dll', 'msedge_elf.dll',
                          'EBWebView\x64\EmbeddedBrowserWebView.dll') {
        $cp = Join-Path $TreeDir $critical
        if (-not (Test-Path $cp)) { throw "critical binary missing: $critical" }
        $csig = Get-AuthenticodeSignature -FilePath $cp
        $csubject = 'unsigned'
        if ($null -ne $csig.SignerCertificate) {
            $csubject = $csig.SignerCertificate.Subject
        }
        if (("$($csig.Status)" -cne 'Valid') -or ($csubject -cne $FxSubject)) {
            throw ("critical binary '$critical' failed the signer axis: " +
                "status=$($csig.Status) subject=$csubject (expected Valid + $FxSubject)")
        }
    }
    Write-Host 'CAP-6b3 critical-binary signer axis PASS (4 binaries, exact subject)'

    # the pinned-SDK loader: the Fixed Runtime package ships none, and this
    # one is covered by webview.lock's extracted-tree sha256
    $loaderSig = Get-AuthenticodeSignature -FilePath $LoaderSrc
    $loaderSubject = 'unsigned'
    if ($null -ne $loaderSig.SignerCertificate) {
        $loaderSubject = $loaderSig.SignerCertificate.Subject
    }
    if (("$($loaderSig.Status)" -cne 'Valid') -or ($loaderSubject -cne $FxSubject)) {
        throw ("pinned-SDK WebView2Loader.dll failed the signer axis: " +
            "status=$($loaderSig.Status) subject=$loaderSubject")
    }
    if (Test-Path (Join-Path $TreeDir 'WebView2Loader.dll')) {
        throw ('the Fixed Runtime package now ships its own WebView2Loader.dll - ' +
            're-ratify which loader this profile bundles before continuing')
    }
    Copy-Item $LoaderSrc (Join-Path $RuntimeDir 'WebView2Loader.dll')

    # the deterministic tree manifest, written AND re-verified by the same
    # native streamed digest the gates use against the INSTALLED tree
    $ManifestFile = Join-Path $RepoRoot 'build/cap6b3/tree.manifest'
    & $Helper --manifest-write $RuntimeDir $ManifestFile
    if ($LASTEXITCODE -ne 0) { throw 'tree manifest write failed' }
    & $Helper --manifest-verify $RuntimeDir $ManifestFile
    if ($LASTEXITCODE -ne 0) { throw 'tree manifest self-verification failed' }
    $manifestHead = (Get-Content $ManifestFile -TotalCount 1)
    if ($manifestHead -cne $ManifestTag) {
        throw "tree manifest header '$manifestHead' is not the helper tag '$ManifestTag'"
    }
    Write-Host "CAP-6b3 tree manifest written and verified: $ManifestFile"

    # --- 6) stage the application payload -------------------------------------
    $Payload = Join-Path $RepoRoot 'build/cap6b3/payload'
    if (Test-Path $Payload) { Remove-Item -Recurse -Force $Payload }
    New-Item -ItemType Directory -Force $Payload | Out-Null
    $Payload = (Resolve-Path $Payload).Path
    Copy-Item build/cap6b3/bin/releaseapp.exe $Payload/
    Copy-Item build/cap6/release/app.pwb $Payload/
    Copy-Item build/cap6/release/webview.dll $Payload/
    Copy-Item build/cap6b3/bin/pwebwv2fixed.exe $Payload/

    # --- 7) compile the setup, capturing the compile listing ------------------
    # the profile-scoped compression override exists because this payload is
    # ~690 MB: the shared lzma2/solid defaults stay untouched for the
    # CAP-6b1/6b2 profiles, which is what keeps their gates green
    # the artifact basename is the manifest's, parsed from it: no /F
    # override, so a rename in the .iss can never leave the build script
    # looking for a file ISCC no longer produces
    $IssFile = Join-Path $RepoRoot 'tools/setup/fixed.iss'
    $issText = Get-Content $IssFile -Raw
    if ($issText -notmatch '(?m)^#define\s+PWEB_SETUP_BASENAME\s+"([^"]+)"\s*$') {
        throw 'tools/setup/fixed.iss does not author the PWEB_SETUP_BASENAME define'
    }
    $SetupBase = $Matches[1]
    if ($SetupBase -ieq 'setup') {
        throw 'the fixed profile may not be named setup: setup.exe is appcompat-shimmed'
    }
    $DistDir = Join-Path $RepoRoot 'dist/windows/fixed-runtime'
    New-Item -ItemType Directory -Force $DistDir | Out-Null
    $ListingFile = Join-Path $RepoRoot 'build/cap6b3/iscc-fixed.log'
    $isccStart = [DateTime]::UtcNow
    & $Iscc "/DPWEB_PAYLOAD_DIR=$Payload" `
        "/DPWEB_RUNTIME_DIR=$RuntimeDir" `
        "/DPWEB_FIXED_TREE=$ExpectedTree" `
        "/DPWEB_FIXED_SUBJECT=$FxSubject" `
        '/DPWEB_COMPRESSION=lzma2/fast' `
        '/DPWEB_SOLID=no' `
        "/O$DistDir" tools/setup/fixed.iss 2>&1 |
        Tee-Object -FilePath $ListingFile
    if ($LASTEXITCODE -ne 0) { throw 'ISCC compile of fixed.iss failed' }
    $isccSeconds = [int]([DateTime]::UtcNow - $isccStart).TotalSeconds
    Write-Host "ISCC wall time: ${isccSeconds}s"
    $SetupExe = Join-Path $DistDir "$SetupBase.exe"
    if (-not (Test-Path $SetupExe)) { throw "fixed setup missing at $SetupExe" }

    # --- 8) payload proof from the compile listing ----------------------------
    # the listing is authoritative evidence of what ISCC actually embedded;
    # every assertion below is against IT, not the staging dirs. Unlike the
    # CAP-6b1/6b2 proofs this one keys on FULL RELATIVE PATHS: a browser
    # tree repeats basenames across locales and subfolders, so collapsing to
    # unique basenames would silently lose files.
    $listing = Get-Content $ListingFile -Raw
    $payloadPrefix = $Payload.TrimEnd('\') + '\'
    $runtimePrefix = $RuntimeDir.TrimEnd('\') + '\'
    $compressed = @(($listing -split "`r?`n") |
        Where-Object { $_ -match '^\s*Compressing: ' } |
        ForEach-Object {
            (($_ -replace '^\s*Compressing: ', '') -replace '\s+\([^)]*\)\s*$', '').Trim()
        } | ForEach-Object {
            if ($_.StartsWith($runtimePrefix, [StringComparison]::Ordinal)) {
                'runtime\' + $_.Substring($runtimePrefix.Length)
            }
            elseif ($_.StartsWith($payloadPrefix, [StringComparison]::Ordinal)) {
                $_.Substring($payloadPrefix.Length)
            }
            else {
                "FOREIGN:$_"
            }
        } | Sort-Object -Unique)
    if ($compressed.Count -eq 0) {
        throw ('compile listing contains no "Compressing:" lines - ISCC output ' +
            "format changed? see $ListingFile")
    }
    $foreign = @($compressed | Where-Object { $_ -like 'FOREIGN:*' })
    if ($foreign) {
        throw ("the setup embedded file(s) from OUTSIDE the staged payload and " +
            "runtime dirs: $($foreign -join ', ')")
    }
    $rootLen = $runtimePrefix.Length
    $expectedRuntime = @(Get-ChildItem $RuntimeDir -Recurse -File -Force |
        ForEach-Object { 'runtime\' + $_.FullName.Substring($rootLen) })
    $expectedSet = @('app.pwb', 'pwebwv2fixed.exe', 'releaseapp.exe',
        'webview.dll') + $expectedRuntime | Sort-Object -Unique
    if (($compressed -join "`n") -cne ($expectedSet -join "`n")) {
        $missing = @($expectedSet | Where-Object { $compressed -cnotcontains $_ })
        $extra = @($compressed | Where-Object { $expectedSet -cnotcontains $_ })
        throw ("embedded payload set drifted: $($missing.Count) missing " +
            "[$(($missing | Select-Object -First 5) -join ', ')], " +
            "$($extra.Count) unexpected [$(($extra | Select-Object -First 5) -join ', ')]")
    }
    # INVERTED from the Evergreen profiles: the browser image is exactly
    # what this profile must embed
    $browserRel = "runtime\$ExpectedTree\msedgewebview2.exe"
    if ($compressed -cnotcontains $browserRel) {
        throw "the bundled runtime browser '$browserRel' is missing from the listing"
    }
    if ($compressed -cnotcontains "runtime\WebView2Loader.dll") {
        throw 'the bundled WebView2Loader.dll is missing from the listing'
    }
    # the fixed profile embeds NEITHER Evergreen installer
    foreach ($banned in $BootFile, $SaFile) {
        if ($listing -match [regex]::Escape($banned)) {
            throw ("FIXED INVARIANT BROKEN: the Evergreen installer '$banned' " +
                'appears in the fixed compile listing')
        }
    }
    # loose frontend files are banned OUTSIDE the runtime subtree only:
    # inside it, .js/.json/.pak are legitimate browser resources
    $loose = @($compressed |
        Where-Object { -not $_.StartsWith('runtime\', [StringComparison]::Ordinal) } |
        Where-Object { $_ -match '\.(html|css|js|map|json)$' })
    if ($loose) {
        throw "loose frontend file(s) embedded: $($loose -join ', ')"
    }
    Write-Host ("CAP-6b3 payload proof PASS (listing: $($compressed.Count) files by " +
        'FULL RELATIVE PATH - release triple + ACL helper + the whole runtime ' +
        'tree; both Evergreen installers absent; no loose frontend outside the tree)')

    # --- 9) abort-probe TEST build (always built, never shipped) --------------
    # the ratified CAP-6b1 abort-probe pattern, applied to this profile's
    # post-install gate: a tiny always-fail stub replaces the helper through
    # the documented PWEB_ACL_HELPER test hook, so the gates can PROVE by
    # automation that a failing gate leaves NOTHING installed. A test
    # artifact under build/, NEVER under dist/.
    $StubName = 'pwebwv2fixedstub.exe'
    @'
program pwebwv2fixedstub;
{ CAP-6b3 abort-probe stub: stands in for the fixed-runtime post-install
  helper in the TEST-ONLY abort-probe setup build. Always fails with the
  signers exit code so the gates can prove that a failing post-install
  gate removes {app} and leaves no launchable app behind. It honours the
  same 4th (logfile) argument as the real helper so its verdict lines
  land in the Inno setup log exactly like a genuine refusal would.
  Never shipped. }
{$mode ObjFPC}{$H+}
{$apptype console}
const
  L1 = 'WV2FIXED_DIAG abort-probe stub: unconditional failure';
  L2 = 'WV2FIXED_RESULT outcome=Failed step=signers';
var
  f: Text;
begin
  writeln(L1);
  writeln(L2);
  if ParamCount >= 4 then
  begin
    Assign(f, ParamStr(4));
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
  ExitCode := 6;
end.
'@ | Set-Content -Encoding ascii build/cap6b3/pwebwv2fixedstub.pas
    fpc -MObjFPC -Sh -B -FUbuild/cap6b3/fpc -FEbuild/cap6b3/bin `
        build/cap6b3/pwebwv2fixedstub.pas
    if ($LASTEXITCODE -ne 0) { throw 'abort-probe stub compile failed' }
    Copy-Item "build/cap6b3/bin/$StubName" $Payload/
    $AbortDir = Join-Path $RepoRoot 'build/cap6b3/abort-probe'
    New-Item -ItemType Directory -Force $AbortDir | Out-Null
    # a stale output from an earlier run can still be HELD by Inno's
    # respawned second stage (abortprobe.tmp) if that run was killed
    # rather than allowed to finish; ISCC would then fail to overwrite
    # it with an opaque error. Clear it here and say so plainly.
    $AbortProbeExe = Join-Path $AbortDir 'abortprobe.exe'
    if (Test-Path $AbortProbeExe) {
        try {
            Remove-Item -Force -LiteralPath $AbortProbeExe -ErrorAction Stop
        }
        catch {
            throw ("cannot replace the stale abort probe $AbortProbeExe - a " +
                'previous abort-probe run is probably still alive (look for ' +
                "abortprobe.tmp): $($_.Exception.Message)")
        }
    }
    & $Iscc "/DPWEB_PAYLOAD_DIR=$Payload" `
        "/DPWEB_RUNTIME_DIR=$RuntimeDir" `
        "/DPWEB_FIXED_TREE=$ExpectedTree" `
        "/DPWEB_FIXED_SUBJECT=$FxSubject" `
        "/DPWEB_ACL_HELPER=$StubName" `
        '/DPWEB_COMPRESSION=lzma2/fast' `
        '/DPWEB_SOLID=no' `
        "/O$AbortDir" '/Fabortprobe' tools/setup/fixed.iss 2>&1 |
        Tee-Object -FilePath (Join-Path $RepoRoot 'build/cap6b3/iscc-abort.log') |
        Out-Null
    if ($LASTEXITCODE -ne 0) {
        # never swallow this: a discarded listing turns a one-line ISCC
        # diagnostic into a blind rebuild
        Get-Content (Join-Path $RepoRoot 'build/cap6b3/iscc-abort.log') |
            Select-Object -Last 15 | Write-Host
        throw 'ISCC compile of the abort-probe setup failed'
    }
    if (-not (Test-Path $AbortProbeExe)) {
        throw "abort-probe setup missing at $AbortProbeExe"
    }

    # size record: a browser tree does not compress 20:1, so a setup that
    # small can not possibly carry the payload. This is a sanity FLOOR, not
    # a size target - the fixed profile has none.
    $SetupSize = (Get-Item $SetupExe).Length
    $floor = [long]($treeBytes / 20)
    if ($SetupSize -lt $floor) {
        throw ("$SetupBase.exe ($SetupSize bytes) is below the sanity floor " +
            "($floor bytes = 1/20 of the $treeBytes-byte tree) - the payload " +
            'cannot be complete')
    }

    # export the exact facts the gates must reuse (single parse point);
    # SetupSha lets the clean-machine gate verify the very setup.exe it is
    # about to execute against THIS build's bytes; psd1 single-quoted
    # strings escape embedded quotes by doubling
    $SetupSha = (Get-FileHash -Algorithm SHA256 $SetupExe).Hash.ToLowerInvariant()
    function ConvertTo-Psd1Value([string]$s) { $s -replace "'", "''" }
    @"
@{
    FixedFile = '$(ConvertTo-Psd1Value $FxFile)'
    FixedSha = '$(ConvertTo-Psd1Value $FxSha)'
    FixedSubject = '$(ConvertTo-Psd1Value $FxSubject)'
    FixedSize = $FxSize
    FixedVersion = '$(ConvertTo-Psd1Value $FxVersion)'
    TreeName = '$(ConvertTo-Psd1Value $ExpectedTree)'
    TreeFiles = $($treeFiles.Count)
    TreeBytes = $treeBytes
    ManifestTag = '$(ConvertTo-Psd1Value $ManifestTag)'
    ManifestFile = '$(ConvertTo-Psd1Value $ManifestFile)'
    RuntimeDir = '$(ConvertTo-Psd1Value $RuntimeDir)'
    Helper = '$(ConvertTo-Psd1Value $Helper)'
    BootFile = '$(ConvertTo-Psd1Value $BootFile)'
    StandaloneFile = '$(ConvertTo-Psd1Value $SaFile)'
    SetupExe = '$(ConvertTo-Psd1Value $SetupExe)'
    SetupSize = $SetupSize
    SetupSha = '$(ConvertTo-Psd1Value $SetupSha)'
    AbortProbeExe = '$(ConvertTo-Psd1Value $AbortProbeExe)'
    IsccSeconds = $isccSeconds
}
"@ | Set-Content -Encoding utf8 build/cap6b3/lockfacts.psd1

    Write-Host "CAP-6b3 fixed setup built: $SetupExe ($SetupSize bytes, sha256 $SetupSha)"
    Write-Host 'CAP6B3_SETUP_BUILD_PASS'
}
finally {
    Pop-Location
}
