# CAP-6b4 PROFILE ISOLATION MATRIX. Three artifacts, one product: each
# setup must carry EXACTLY its own profile's payload and none of the
# other two profiles' artifacts.
#
#   normal        = release triple + provisioning helper + the Evergreen
#                   BOOTSTRAPPER          (no standalone, no runtime tree)
#   offline       = release triple + provisioning helper + the Evergreen
#                   STANDALONE            (no bootstrapper, no runtime tree)
#   fixed-runtime = release triple + ACL helper + the whole FIXED RUNTIME
#                   TREE                  (neither Evergreen installer)
#
# The evidence is ISCC's OWN compile listing for each profile, recorded
# by the three build scripts - not the staging directories, and not the
# built binary. A staging dir says what we meant to embed; the listing
# says what the compiler actually embedded.
#
# This gate is entirely mechanical: it installs nothing, executes no
# setup and touches no machine state. Every per-profile payload proof
# the three build scripts already perform stays where it is; what is
# added here is the CROSS-profile view none of them can have, plus the
# size envelopes and the integrity of the release index the CAP-6b4
# orchestrator writes.
#
#   1. listing parse: each profile's embedded set, by BASENAME for the
#      two Evergreen profiles and by FULL RELATIVE PATH for the fixed
#      one (a browser tree repeats basenames across locales, so
#      collapsing them would silently lose files)
#   2. exclusivity: each profile's listing contains its own ratified
#      artifact and NEITHER of the other two profiles' artifacts
#   3. size envelopes: a setup can never be smaller than the already
#      compressed payload it embeds
#   4. release-index integrity: every entry names a ratified profile and
#      basename, and its bytes/sha256 match the artifact on disk
#
# Usage: pwsh -File test/cap6b4/run_profile_isolation.ps1

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Push-Location $RepoRoot
try {
    foreach ($pre in 'build/cap6b1/iscc-normal.log',
                     'build/cap6b2/iscc-offline.log',
                     'build/cap6b3/iscc-fixed.log',
                     'build/cap6b1/lockfacts.psd1',
                     'build/cap6b2/lockfacts.psd1',
                     'build/cap6b3/lockfacts.psd1',
                     'webview2-runtime.lock',
                     'dist/windows/release-index.json') {
        if (-not (Test-Path $pre)) {
            throw ("missing precondition: $pre -- run " +
                'pwsh -File tools/build-windows-profiles.ps1 first (it builds ' +
                'all three profiles and writes the release index)')
        }
    }
    $NormalFacts = Import-PowerShellDataFile (Resolve-Path build/cap6b1/lockfacts.psd1).Path
    $OfflineFacts = Import-PowerShellDataFile (Resolve-Path build/cap6b2/lockfacts.psd1).Path
    $FixedFacts = Import-PowerShellDataFile (Resolve-Path build/cap6b3/lockfacts.psd1).Path

    $BootFile = $NormalFacts.BootFile
    $SaFile = $OfflineFacts.StandaloneFile
    $TreeName = $FixedFacts.TreeName
    foreach ($pair in @{ BootFile = $BootFile; StandaloneFile = $SaFile;
        TreeName = $TreeName }.GetEnumerator()) {
        if (-not $pair.Value) {
            throw "the exported lock facts carry no $($pair.Key) - rebuild the profiles"
        }
    }

    # Set comparisons below are byte-exact and case-SENSITIVE (-ccontains
    # / -cnotcontains / -cne), so the sets they run over must be
    # de-duplicated the same way. PowerShell's Sort-Object -Unique folds
    # case, which would collapse two paths differing only in case BEFORE
    # the strict comparison ever saw them - exactly the drift these
    # proofs exist to catch.
    function Sort-Ordinal([string[]]$In) {
        $set = [System.Collections.Generic.SortedSet[string]]::new(
            [System.StringComparer]::Ordinal)
        foreach ($x in $In) { [void]$set.Add($x) }
        @($set)
    }

    # --- 1) the listings, parsed the way each profile's payload demands -------
    # ISCC may append a parenthesized progress/size suffix and a progress
    # refresh may repeat a line: strip the suffix, collapse duplicates.
    function Get-CompressedPaths([string]$ListingFile) {
        $lines = @((Get-Content $ListingFile -Raw) -split "`r?`n" |
            Where-Object { $_ -match '^\s*Compressing: ' } |
            ForEach-Object {
                (($_ -replace '^\s*Compressing: ', '') -replace '\s+\([^)]*\)\s*$', '').Trim()
            })
        if ($lines.Count -eq 0) {
            throw ("compile listing contains no `"Compressing:`" lines - ISCC " +
                "output format changed? see $ListingFile")
        }
        $lines
    }
    $normalFull = Get-CompressedPaths 'build/cap6b1/iscc-normal.log'
    $offlineFull = Get-CompressedPaths 'build/cap6b2/iscc-offline.log'
    $fixedFull = Get-CompressedPaths 'build/cap6b3/iscc-fixed.log'

    $normalSet = Sort-Ordinal @($normalFull | ForEach-Object { Split-Path -Leaf $_ })
    $offlineSet = Sort-Ordinal @($offlineFull | ForEach-Object { Split-Path -Leaf $_ })
    # the fixed profile keys on full relative paths under the two staged
    # roots the build declared, so a browser tree's repeated basenames
    # can never collapse
    $runtimePrefix = ([string]$FixedFacts.RuntimeDir).TrimEnd('\') + '\'
    $fixedRel = Sort-Ordinal @($fixedFull | ForEach-Object {
        if ($_.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            'runtime\' + $_.Substring($runtimePrefix.Length)
        }
        else { Split-Path -Leaf $_ }
    })

    $Triple = @('app.pwb', 'releaseapp.exe', 'webview.dll')

    # --- 2) exclusivity, per profile -----------------------------------------
    # every profile carries the release triple - that is the product
    foreach ($case in @(
            @{ Name = 'normal'; Set = $normalSet },
            @{ Name = 'offline'; Set = $offlineSet },
            @{ Name = 'fixed-runtime'; Set = $fixedRel })) {
        foreach ($t in $Triple) {
            if ($case.Set -cnotcontains $t) {
                throw "the $($case.Name) profile does not embed the release triple member '$t'"
            }
        }
    }

    # normal: the bootstrapper and nothing else Microsoft ships
    $expectedNormal = Sort-Ordinal @($Triple + @($BootFile, 'pwebwv2prov.exe'))
    if (($normalSet -join ',') -cne ($expectedNormal -join ',')) {
        throw ("normal profile payload drifted: listing shows " +
            "[$($normalSet -join ', ')], expected exactly [$($expectedNormal -join ', ')]")
    }
    # offline: the standalone and nothing else Microsoft ships
    $expectedOffline = Sort-Ordinal @($Triple + @($SaFile, 'pwebwv2prov.exe'))
    if (($offlineSet -join ',') -cne ($expectedOffline -join ',')) {
        throw ("offline profile payload drifted: listing shows " +
            "[$($offlineSet -join ', ')], expected exactly [$($expectedOffline -join ', ')]")
    }
    # fixed: the tree, the ACL helper, and NO provisioning helper at all
    if ($fixedRel -cnotcontains 'pwebwv2fixed.exe') {
        throw 'the fixed profile does not embed its ACL helper'
    }
    if ($fixedRel -ccontains 'pwebwv2prov.exe') {
        throw 'FIXED INVARIANT BROKEN: the fixed profile embeds the provisioning helper'
    }
    $browserRel = "runtime\$TreeName\msedgewebview2.exe"
    if ($fixedRel -cnotcontains $browserRel) {
        throw "the fixed profile does not embed the bundled browser image '$browserRel'"
    }
    if ($fixedRel -cnotcontains 'runtime\WebView2Loader.dll') {
        throw 'the fixed profile does not embed the bundled WebView2Loader.dll'
    }
    $treeCount = @($fixedRel | Where-Object {
        $_.StartsWith('runtime\', [StringComparison]::Ordinal) }).Count
    # the loader sits beside the tree, so the count is the tree + 1
    if ($treeCount -ne ([int]$FixedFacts.TreeFiles + 1)) {
        throw ("the fixed profile embeds $treeCount runtime file(s); the build " +
            "recorded a $($FixedFacts.TreeFiles)-file tree plus the bundled loader")
    }

    # the CROSS-profile bans, the whole point of this gate
    $Bans = @(
        @{ Profile = 'normal'; Set = $normalSet
           Banned = @($SaFile, 'pwebwv2fixed.exe') },
        @{ Profile = 'offline'; Set = $offlineSet
           Banned = @($BootFile, 'pwebwv2fixed.exe') },
        @{ Profile = 'fixed-runtime'; Set = $fixedRel
           Banned = @($BootFile, $SaFile, 'pwebwv2prov.exe') }
    )
    foreach ($b in $Bans) {
        foreach ($banned in $b.Banned) {
            if ($b.Set -ccontains $banned) {
                throw ("ISOLATION BROKEN: the $($b.Profile) profile embeds " +
                    "'$banned', which belongs to another profile")
            }
        }
    }
    # no runtime tree may reach an Evergreen profile, by any spelling
    foreach ($case in @(@{ Name = 'normal'; Full = $normalFull },
                        @{ Name = 'offline'; Full = $offlineFull })) {
        $treeHits = @($case.Full | Where-Object {
            $_ -match '(?i)msedgewebview2|EmbeddedBrowserWebView|WebView2Loader' })
        if ($treeHits) {
            throw ("ISOLATION BROKEN: the $($case.Name) profile embeds Fixed " +
                "Runtime tree file(s): $(($treeHits | Select-Object -First 3) -join ', ')")
        }
    }
    # loose frontend files are banned everywhere OUTSIDE the runtime subtree
    # (inside it, .js/.json/.pak are legitimate browser resources)
    foreach ($case in @(@{ Name = 'normal'; Set = $normalSet },
                        @{ Name = 'offline'; Set = $offlineSet },
                        @{ Name = 'fixed-runtime'; Set = $fixedRel })) {
        $loose = @($case.Set |
            Where-Object { -not $_.StartsWith('runtime\', [StringComparison]::Ordinal) } |
            Where-Object { $_ -match '\.(html|css|js|map|json)$' })
        if ($loose) {
            throw "the $($case.Name) profile embeds loose frontend file(s): $($loose -join ', ')"
        }
    }
    Write-Host ("CAP-6b4 isolation gate 1 PASS (normal=$($normalSet.Count) file(s), " +
        "offline=$($offlineSet.Count), fixed=$($fixedRel.Count) by full relative " +
        'path; each profile carries its own Microsoft artifact and neither of the ' +
        "other two profiles')")

    # --- 3) size envelopes ----------------------------------------------------
    # the embedded payload is already compressed, so a setup smaller than
    # what it embeds cannot be complete. These are FLOORS, not targets.
    $lockLines = Get-Content (Join-Path $RepoRoot 'webview2-runtime.lock')
    $bootSize = 0
    $section = ''
    foreach ($raw in $lockLines) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '=') { continue }
        $k, $v = $line -split '=', 2
        $k = $k.Trim(); $v = $v.Trim()
        if ($k -ceq 'artifact') { $section = $v; continue }
        if (($section -ceq 'evergreen-bootstrapper') -and ($k -ceq 'size')) {
            $bootSize = [long]$v
        }
    }
    if ($bootSize -le 0) {
        throw "webview2-runtime.lock: evergreen-bootstrapper has no usable 'size'"
    }
    $Envelopes = @(
        @{ Profile = 'normal'; Artifact = $NormalFacts.SetupExe; Floor = $bootSize
           Why = "the embedded Bootstrapper ($bootSize bytes)" },
        @{ Profile = 'offline'; Artifact = $OfflineFacts.SetupExe
           Floor = [long]$OfflineFacts.StandaloneSize
           Why = "the embedded Standalone ($($OfflineFacts.StandaloneSize) bytes)" },
        @{ Profile = 'fixed-runtime'; Artifact = $FixedFacts.SetupExe
           Floor = [long]([long]$FixedFacts.TreeBytes / 20)
           Why = "1/20 of the $($FixedFacts.TreeBytes)-byte runtime tree" }
    )
    foreach ($e in $Envelopes) {
        if (-not (Test-Path -LiteralPath $e.Artifact)) {
            throw "the $($e.Profile) artifact is missing: $($e.Artifact)"
        }
        # a missing lockfacts key casts to 0, and every setup is bigger
        # than 0 - the envelope would pass having proven nothing
        if ($e.Floor -le 0) {
            throw ("the $($e.Profile) size floor resolved to $($e.Floor) - the " +
                'exported lock facts are missing the key it is derived from, so ' +
                'this envelope would pass vacuously')
        }
        $size = (Get-Item -LiteralPath $e.Artifact).Length
        if ($size -lt $e.Floor) {
            throw ("the $($e.Profile) setup ($size bytes) is below its sanity " +
                "floor - $($e.Why) - so its payload cannot be complete")
        }
        Write-Host ("  $($e.Profile): $size bytes (floor $($e.Floor) = $($e.Why))")
    }
    Write-Host 'CAP-6b4 isolation gate 2 PASS (all three setups clear their payload floors)'

    # --- 4) release-index integrity ------------------------------------------
    $doc = Get-Content (Join-Path $RepoRoot 'dist/windows/release-index.json') -Raw |
        ConvertFrom-Json
    # THE SEAM. The document carries a schema version, and this gate keys
    # on it: everything below freezes the shape of SCHEMA 1. A future
    # CAP-10 that needs another field bumps the schema and teaches this
    # gate the new shape, rather than being unable to add anything
    # without editing a CAP-6b4 proof.
    $KnownSchema = 1
    if ($null -eq $doc.schema) {
        throw ('release-index.json carries no schema version - the CAP-10 seam ' +
            'depends on it')
    }
    if ([int]$doc.schema -ne $KnownSchema) {
        throw ("release-index.json declares schema $($doc.schema); this gate knows " +
            "schema $KnownSchema. Teach it the new shape deliberately rather than " +
            'letting an unknown document pass unchecked')
    }
    $index = @($doc.profiles)
    $ExpectedIndex = [ordered]@{
        'normal'        = @{ Basename = 'PWebRelease-Normal-Setup.exe'
                             Artifact = $NormalFacts.SetupExe }
        'offline'       = @{ Basename = 'PWebRelease-Offline-Setup.exe'
                             Artifact = $OfflineFacts.SetupExe }
        'fixed-runtime' = @{ Basename = 'PWebRelease-FixedRuntime-Setup.exe'
                             Artifact = $FixedFacts.SetupExe }
    }
    if ($index.Count -ne $ExpectedIndex.Count) {
        throw ("release-index.json lists $($index.Count) profile(s); the product " +
            "has exactly $($ExpectedIndex.Count)")
    }
    $seenProfiles = @{}
    foreach ($entry in $index) {
        if (-not $ExpectedIndex.Contains($entry.profile)) {
            throw "release-index.json names an unratified profile '$($entry.profile)'"
        }
        if ($seenProfiles.ContainsKey($entry.profile)) {
            throw "release-index.json lists profile '$($entry.profile)' twice"
        }
        $seenProfiles[$entry.profile] = $true
        $want = $ExpectedIndex[$entry.profile]
        if ($entry.filename -cne $want.Basename) {
            throw ("release-index.json says the $($entry.profile) artifact is " +
                "'$($entry.filename)'; the ratified basename is '$($want.Basename)'")
        }
        if ($entry.filename -ieq 'setup.exe') {
            throw 'release-index.json ships an artifact named setup.exe'
        }
        # the index must describe the bytes that actually exist
        $item = Get-Item -LiteralPath $want.Artifact
        if ([long]$entry.bytes -ne $item.Length) {
            throw ("release-index.json records $($entry.bytes) bytes for " +
                "$($entry.profile); the artifact is $($item.Length) bytes")
        }
        $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $want.Artifact).Hash.ToLowerInvariant()
        if ("$($entry.sha256)" -cne $sha) {
            throw ("release-index.json records sha256 $($entry.sha256) for " +
                "$($entry.profile); the artifact hashes to $sha")
        }
        # SCHEMA 1: the index is a manifest, not a build log - it carries
        # exactly the four ratified keys and nothing a future CLI would
        # have to ignore. A schema bump is how extra fields arrive.
        $keys = @($entry.PSObject.Properties.Name | Sort-Object)
        $wantKeys = @('bytes', 'filename', 'profile', 'sha256')
        if (($keys -join ',') -cne ($wantKeys -join ',')) {
            throw ("release-index.json (schema $KnownSchema) entry for " +
                "$($entry.profile) carries keys [$($keys -join ', ')]; the " +
                "ratified shape is [$($wantKeys -join ', ')] - add fields by " +
                'bumping the schema, not by widening schema 1')
        }
    }
    Write-Host ("CAP-6b4 isolation gate 3 PASS (release index: $($index.Count) " +
        'ratified profiles, exact basenames, bytes and sha256 measured against ' +
        'the artifacts on disk)')

    if ($env:GITHUB_STEP_SUMMARY) {
        ("### CAP-6b4 profile isolation`nPASS - each of the three setups embeds " +
         'exactly its own profile payload (ISCC listings), clears its size floor, ' +
         'and is described exactly by dist/windows/release-index.json') |
            Out-File -Append $env:GITHUB_STEP_SUMMARY
    }
    Write-Host 'CAP6B4_ISOLATION_PASS'
}
finally {
    Pop-Location
}
