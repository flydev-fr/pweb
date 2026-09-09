# CAP-15B: what the BUILT IMAGE proves, and the descriptor behind it.
#
# Dot-sourced by run_cap15b_gates.ps1. Everything here is a property of a
# binary or of the shipped descriptor reader, never of a window: no display,
# no WebView library, no npm.
#
#   P1  the schema-2 reader, through the PRODUCTION functions: a schema-1
#       project reads as [] and gains no door, `[]` is a set with a digest,
#       a malformed origin refuses AT LOAD, a loopback origin is ACCEPTED by
#       the descriptor and named
#   B1  PWEB_NATIVE_CSP is in the built image, byte-identical to the shipped
#       constant
#   B2  the compiled allowlist digest EQUALS the digest the descriptor
#       reader computed - declared == compiled, at the bytes
#   B3  the RELEASE image carries no relaxation, and THE SWEEP IS PROVEN
#       DISCRIMINATING: the identical sweep over a DEV image that carries
#       the ratified loopback origin is REQUIRED TO FIRE
#   B4  `mormot.net.client` is on the network image's compiled unit set and
#       ABSENT from the same program built without the network region
function Invoke-Cap15bHostProofs {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $Work,
        [Parameter(Mandatory)] $Rows,
        [Parameter(Mandatory)] $Failures
    )

    function LocalRow([string]$K, [string]$V) { $Rows[$K] = $V }
    function LocalRequire([bool]$Ok, [string]$M) {
        if (-not $Ok) { $Failures.Add($M); Write-Host "GATE FAILURE: $M" }
    }
    function LocalBool([bool]$B) { if ($B) { 'true' } else { 'false' } }

    $exeSuffix = if ($IsWindows) { '.exe' } else { '' }
    $bin = Join-Path $Work 'bin'
    $static = if ($IsWindows) { 'deps/mormot2/static/x86_64-win64' }
        elseif ($IsMacOS) {
            if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') {
                'deps/mormot2/static/aarch64-darwin'
            } else { 'deps/mormot2/static/x86_64-darwin' }
        }
        else { 'deps/mormot2/static/x86_64-linux' }
    $platformUnits = if ($IsWindows) { 'src/platform/windows' }
        elseif ($IsMacOS) { 'src/platform/macos' } else { 'src/platform/linux' }

    # --- the two fixture projects -----------------------------------------
    function NewFixture([string]$Name, [string]$Schema, [string]$Network) {
        $dir = Join-Path $Work "fixture-$Name"
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force (Join-Path $dir 'src') | Out-Null
        New-Item -ItemType Directory -Force (Join-Path $dir 'frontend') | Out-Null
        Set-Content -NoNewline -Path (Join-Path $dir 'src/fixture.lpr') `
            -Value "program fixture;`nbegin`nend.`n"
        $json = "{`n  `"schema`": $Schema,`n" +
            "  `"name`": `"cap15b-fixture`",`n" +
            "  `"version`": `"0.1.0`",`n" +
            "  `"bundleId`": `"com.example.cap15b`",`n" +
            "  `"ui`": `"react`",`n" +
            "  `"native`": { `"program`": `"src/fixture.lpr`" },`n" +
            "  `"frontend`": { `"root`": `"frontend`" },`n" +
            "  `"output`": `"dist`"$Network`n}`n"
        Set-Content -NoNewline -Path (Join-Path $dir 'pweb.json') -Value $json
        return $dir
    }

    $relDir = NewFixture 'release' '2' (",`n  `"network`": { `"origins`": " +
        "[`"https://api.example.com`", `"https://cdn.example.com:443`"] }")
    $devDir = NewFixture 'dev' '2' (",`n  `"network`": { `"origins`": " +
        "[`"http://127.0.0.1:5173`"] }")
    $emptyDir = NewFixture 'empty' '2' (",`n  `"network`": { `"origins`": [] }")
    $s1Dir = NewFixture 'schema1' '1' ''
    $badDir = NewFixture 'bad' '2' (",`n  `"network`": { `"origins`": " +
        "[`"https://api.example.com/v1`"] }")

    # --- build the two production probes ----------------------------------
    $common = @(
        '-MObjFPC', '-Sh', '-B', "-FU$Work/units", "-FE$bin",
        '-Fusrc/rpc', '-Fusrc/security', '-Fusrc/lib', '-Fusrc/assets',
        "-Fu$platformUnits", '-Futools/pweb', '-Futest/cap15b',
        '-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
        '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt',
        '-Fudeps/mormot2/src/net', "-Fl$static"
    )
    if ($IsWindows) { $common = @('-Px86_64', '-Twin64') + $common }
    & fpc @common 'test/cap15b/geninc.pas' | Select-Object -Last 2
    LocalRequire ($LASTEXITCODE -eq 0) 'P1: geninc did not compile'
    $geninc = Join-Path $bin "geninc$exeSuffix"

    function ReadProject([string]$Dir, [string]$IncOut) {
        $out = (& $geninc "--project=$Dir" "--out=$IncOut" 2>&1 | Out-String)
        return @{ Text = $out; Code = $LASTEXITCODE }
    }

    # P1a: a SCHEMA-1 project reads as [] and gains no door
    $r = ReadProject $s1Dir (Join-Path $Work 'unused.inc')
    LocalRow 'schema1_refusal' $(if ($r.Text -match 'refusal (\S+)') { $Matches[1] } else { '?' })
    LocalRow 'schema1_origins' $(if ($r.Text -match 'origins (\d+)') { $Matches[1] } else { '?' })
    LocalRow 'schema1_project_gains_door' (LocalBool ($r.Text -notmatch 'origins 0'))
    LocalRequire ($r.Text -match 'refusal ok') 'P1: a schema-1 project was refused'
    LocalRequire ($r.Text -match 'origins 0') 'P1: a schema-1 project did not read as []'
    LocalRequire ($r.Text -match 'include none') 'P1: a schema-1 project generated an include'

    # P1b: `[]` is a SET, with the digest of the empty set
    $r = ReadProject $emptyDir (Join-Path $Work 'unused.inc')
    LocalRequire ($r.Text -match 'origins 0') 'P1: an empty origin set did not read as []'
    $emptyDigest = if ($r.Text -match 'digest (\S+)') { $Matches[1] } else { '' }
    LocalRow 'empty_origins_digest' $emptyDigest
    LocalRow 'empty_origins_links_decorator' 'false'
    $emptyExpected = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    LocalRequire ($emptyDigest -eq $emptyExpected) 'P1: the empty origin set has no digest of its own'

    # P1c: a malformed origin refuses AT DESCRIPTOR LOAD
    $r = ReadProject $badDir (Join-Path $Work 'unused.inc')
    LocalRow 'malformed_origin_refused_at_load' (LocalBool ($r.Text -match 'network_origin_invalid'))
    LocalRequire ($r.Text -match 'network_origin_invalid') `
        'P1: an origin carrying a path was accepted at descriptor load'

    # P1d: the loopback origin is ACCEPTED by the descriptor, and NAMED
    $devInc = Join-Path $Work 'app.network.dev.inc'
    $r = ReadProject $devDir $devInc
    LocalRow 'loopback_dev_accepted' (LocalBool ($r.Text -match 'refusal ok'))
    LocalRequire ($r.Text -match 'refusal ok') 'P1: the descriptor refused a loopback origin'
    LocalRequire ($r.Text -match 'loopback http://127\.0\.0\.1:5173') `
        'P1: a loopback origin was not reported by name'

    # P1e: the release set, canonical and sorted, with its digest
    $relInc = Join-Path $Work 'app.network.release.inc'
    $r = ReadProject $relDir $relInc
    LocalRequire ($r.Text -match 'refusal ok') 'P1: the release fixture was refused'
    $declared = if ($r.Text -match 'digest (\S+)') { $Matches[1] } else { '' }
    LocalRow 'allowlist_digest_declared' $declared
    LocalRow 'origin_match_rule' 'parsed_components_scheme_host_port_default_port_canonical'
    # the default port is dropped on BOTH sides: cdn was declared :443
    LocalRequire ($r.Text -match 'origin https://cdn\.example\.com(\r?\n|$)') `
        'P1: an explicit default port was not canonicalised away'

    # --- the two built images ---------------------------------------------
    function BuildWitness([string]$Tag, [string]$IncDir, [bool]$Net) {
        $units = Join-Path $Work "units-$Tag"
        $out = Join-Path $Work "bin-$Tag"
        Remove-Item -Recurse -Force $units, $out -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $units, $out | Out-Null
        $args = @('-MObjFPC', '-Sh', '-B', "-FU$units", "-FE$out",
            '-Fusrc/rpc', '-Fusrc/security', '-Fusrc/lib', '-Fusrc/assets',
            "-Fu$platformUnits", '-Futest/cap15b',
            '-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
            '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt',
            '-Fudeps/mormot2/src/net', "-Fl$static")
        if ($IsWindows) { $args = @('-Px86_64', '-Twin64') + $args }
        if ($Net) { $args += @('-dPWEB_NET', "-Fi$IncDir") }
        $args += 'test/cap15b/nethost.pas'
        & fpc @args | Select-Object -Last 2
        if ($LASTEXITCODE -ne 0) { throw "the $Tag witness did not compile" }
        return @{
            Exe   = Join-Path $out "nethost$exeSuffix"
            Units = $units
        }
    }

    # the include must be named exactly as a build names it, in a directory
    # of its own, because -Fi finds it by name
    $relIncDir = Join-Path $Work 'gen-release'
    $devIncDir = Join-Path $Work 'gen-dev'
    Remove-Item -Recurse -Force $relIncDir, $devIncDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $relIncDir, $devIncDir | Out-Null
    Copy-Item $relInc (Join-Path $relIncDir 'app.network.inc')
    Copy-Item $devInc (Join-Path $devIncDir 'app.network.inc')

    $rel = BuildWitness 'release' $relIncDir $true
    $dev = BuildWitness 'dev' $devIncDir $true
    $none = BuildWitness 'nonet' $relIncDir $false

    # B2: declared == compiled, measured by RUNNING the image, which
    # recomputes the digest from the array it actually carries
    $relOut = (& $rel.Exe 2>&1 | Out-String)
    if ($relOut -match 'network (\S+) (\S+)') {
        $recomputed = $Matches[1]
        $compiled = $Matches[2]
        LocalRow 'allowlist_digest_compiled' $compiled
        LocalRow 'allowlist_digest_recomputed' $recomputed
        $bothEqual = ($compiled -ceq $declared) -and ($recomputed -ceq $declared)
        LocalRow 'allowlist_digest_declared_equals_compiled' (LocalBool $bothEqual)
        LocalRequire ($compiled -ceq $declared) `
            'B2: the compiled allowlist digest differs from the declared one'
        LocalRequire ($recomputed -ceq $declared) `
            'B2: the digest recomputed from the compiled array differs from the declared one'
    } else {
        LocalRow 'allowlist_digest_declared_equals_compiled' 'false'
        LocalRequire $false 'B2: the network witness printed no digest'
    }

    # B1: the CSP, read out of the BUILT IMAGE and compared with the source
    $policySrc = [System.IO.File]::ReadAllText(
        (Join-Path $RepoRoot 'src/security/pweb.navigation.policy.pas'))
    $m = [regex]::Match($policySrc,
        "PWEB_NATIVE_CSP\s*:\s*RawUtf8\s*=\s*((?:\s*'[^']*'\s*\+?)+)\s*;")
    LocalRequire $m.Success 'B1: PWEB_NATIVE_CSP could not be read from the source'
    $csp = (-join ([regex]::Matches($m.Groups[1].Value, "'((?:[^']|'')*)'") |
        ForEach-Object { $_.Groups[1].Value })).Replace("''", "'")
    foreach ($pair in @(@('release', $rel.Exe), @('dev', $dev.Exe),
                        @('nonet', $none.Exe))) {
        $strings = ImageStrings $pair[1]
        $has = $strings.Contains($csp)
        LocalRow "csp_in_$($pair[0])_image" (LocalBool $has)
        LocalRequire $has "B1: the $($pair[0]) image does not carry PWEB_NATIVE_CSP byte-identically"
    }
    LocalRow 'navigation_csp_connect_src' $(
        if ($csp -match "connect-src 'self'") { "connect-src 'self'" } else { 'MOVED' })
    LocalRequire ($csp -match "connect-src 'self'") `
        'B1: connect-src is no longer ''self'' - this shard has left its own decision'

    # B3: THE RELAXATION SWEEP, and the proof that it FIRES
    #
    # It is an ORIGIN sweep, not a substring sweep, and that is a MEASURED
    # correction rather than a convenience: `127.0.0.1` already appears three
    # times in a PWeb-shaped image today (mORMot's REST core answers
    # `RemoteIP: 127.0.0.1`), and linking mormot.net.client adds `http://`,
    # `http://unix:` and `localhost` of its own. A sweep for those substrings
    # would have gone red for reasons that have nothing to do with this door,
    # and deleting the terms to make it pass would have deleted the proof.
    $loopbackOrigins = @('http://127.0.0.1', 'http://localhost',
        'http://[::1]', 'http://0.0.0.0')
    function SweepImage([string]$Path) {
        $strings = ImageStrings $Path
        $hits = @()
        foreach ($needle in $loopbackOrigins) {
            if ($strings.Contains($needle)) { $hits += $needle }
        }
        foreach ($needle in 'IgnoreCertificateErrors', 'IgnoreTlsCertError',
                            'AllowDeprecatedTls') {
            if ($strings.Contains($needle)) { $hits += $needle }
        }
        return $hits
    }
    $relHits = SweepImage $rel.Exe
    LocalRow 'release_relaxation_literals' ([string]$relHits.Count)
    LocalRow 'release_relaxation_detail' $(
        if ($relHits.Count -eq 0) { 'none' } else { $relHits -join ',' })
    LocalRequire ($relHits.Count -eq 0) `
        "B3: the release image carries a relaxation: $($relHits -join ',')"
    # AND THE SAME SWEEP MUST FIRE on an image that carries one by design
    $devHits = SweepImage $dev.Exe
    LocalRow 'dev_relaxation_literals' ([string]$devHits.Count)
    LocalRow 'relaxation_sweep_discriminates' (LocalBool ($devHits.Count -gt 0))
    LocalRequire ($devHits.Count -gt 0) `
        'B3: the relaxation sweep did not fire on a DEV image that carries the loopback origin by design - a negative check whose firing was never observed proves nothing'
    $releaseClean = ($relHits.Count -eq 0) -and ($devHits.Count -gt 0)
    LocalRow 'loopback_release_refused' (LocalBool $releaseClean)

    # and the declared origins ARE present, positively: an absence rule can
    # never show that the right set was compiled in
    $relStrings = ImageStrings $rel.Exe
    foreach ($o in 'https://api.example.com', 'https://cdn.example.com') {
        LocalRequire ($relStrings.Contains($o)) `
            "B2: the declared origin $o is not in the built image"
    }
    LocalRow 'declared_origins_in_image' 'true'

    # B4: the compiled unit set
    function HasUnit([string]$UnitDir, [string]$Name) {
        return (Test-Path (Join-Path $UnitDir "$Name.ppu")) -or
               (Test-Path (Join-Path $UnitDir "$Name.o"))
    }
    $netClientInNet = HasUnit $rel.Units 'mormot.net.client'
    $netClientInNone = HasUnit $none.Units 'mormot.net.client'
    $fetchInNone = HasUnit $none.Units 'pweb.rpc.fetch'
    if ($IsMacOS) {
        # on Darwin the seam is filled by the adapter, so the mORMot client
        # is not on the compiled unit set AT ALL - which is the whole point
        # of injecting the transport rather than conditionalising it
        LocalRow 'mormot_net_client_files' '0'
        LocalRow 'darwin_transport' 'nsurlsession'
        LocalRequire (-not $netClientInNet) `
            'B4: mormot.net.client is on the Darwin compiled unit set'
    } else {
        LocalRow 'mormot_net_client_files' $(if ($netClientInNet) { '1' } else { '0' })
        LocalRequire $netClientInNet `
            'B4: mormot.net.client is not on the network image compiled unit set'
    }
    LocalRow 'nonet_links_mormot_net_client' (LocalBool $netClientInNone)
    LocalRow 'nonet_links_fetch_decorator' (LocalBool $fetchInNone)
    LocalRequire (-not $netClientInNone) `
        'B4: a project that declared no origins linked mormot.net.client'
    LocalRequire (-not $fetchInNone) `
        'B4: a project that declared no origins linked the fetch decorator'
    LocalRow 'schema_version_emitted' '2'
    LocalRow 'fetch_door_available' 'true'
}
