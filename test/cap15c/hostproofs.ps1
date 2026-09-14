# CAP-15C: what the BUILT IMAGE proves about the socket door.
#
# Dot-sourced by run_cap15c_gates.ps1. Everything here is a property of a
# binary, never of a window: no display, no WebView library, no npm. The
# shape is CAP-15B's (test/cap15b/hostproofs.ps1), with the socket twin:
#
#   B1  PWEB_NATIVE_CSP is in every image, byte-identical to the shipped
#       constant, and connect-src is still 'self'
#   B2  the socket decorator, network.socket and pweb.socketOpen are in the
#       image IFF the network region was compiled; the running image reports
#       the door with the compiled allowlist digest equal to the declared one
#   B3  the release image carries no ws:// loopback literal, and THE SAME
#       SWEEP IS REQUIRED TO FIRE on a twin that plants one. A development
#       image cannot be that twin, and the row says so by measuring it: the
#       door derives a ws authority from a declared http loopback origin by
#       parsed components, so no image this product builds carries the
#       literal - which is exactly why a negative check over it would be
#       vacuous without a planted firing case
#   B4  the compiled unit set: mormot.net.sock and the socket transport on
#       Windows and Linux, NO mormot.net.ws.* and NO mormot.net.server
#       anywhere, the Cocoa adapter and no mORMot transport on Darwin, and
#       neither the decorator nor a transport in an image without origins
function Invoke-Cap15cHostProofs {
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
    # every printable ASCII run of 4+ bytes in a binary - what `strings`
    # would read, without needing one on four platforms
    function ImageStrings([string]$Path) {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $sb = New-Object System.Text.StringBuilder
        $out = New-Object System.Text.StringBuilder
        foreach ($b in $bytes) {
            if ($b -ge 0x20 -and $b -lt 0x7f) { [void]$sb.Append([char]$b) }
            else {
                if ($sb.Length -ge 4) { [void]$out.AppendLine($sb.ToString()) }
                [void]$sb.Clear()
            }
        }
        if ($sb.Length -ge 4) { [void]$out.AppendLine($sb.ToString()) }
        return $out.ToString()
    }

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

    # --- the fixtures, read by the PRODUCTION descriptor reader -----------
    function NewFixture([string]$Name, [string]$Origins) {
        $dir = Join-Path $Work "fixture-$Name"
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force (Join-Path $dir 'src'),
            (Join-Path $dir 'frontend') | Out-Null
        Set-Content -NoNewline -Path (Join-Path $dir 'src/fixture.lpr') `
            -Value "program fixture;`nbegin`nend.`n"
        $json = "{`n  `"schema`": 2,`n" +
            "  `"name`": `"cap15c-fixture`",`n" +
            "  `"version`": `"0.1.0`",`n" +
            "  `"bundleId`": `"com.example.cap15c`",`n" +
            "  `"ui`": `"react`",`n" +
            "  `"native`": { `"program`": `"src/fixture.lpr`" },`n" +
            "  `"frontend`": { `"root`": `"frontend`" },`n" +
            "  `"output`": `"dist`",`n" +
            "  `"network`": { `"origins`": $Origins }`n}`n"
        Set-Content -NoNewline -Path (Join-Path $dir 'pweb.json') -Value $json
        return $dir
    }
    $relDir = NewFixture 'release' '["https://api.example.com", "https://cdn.example.com:443"]'
    $devDir = NewFixture 'dev' '["http://127.0.0.1:5173"]'

    $genUnits = Join-Path $Work 'units-geninc'
    New-Item -ItemType Directory -Force $genUnits, $bin | Out-Null
    $genArgs = @('-MObjFPC', '-Sh', '-B', "-FU$genUnits", "-FE$bin",
        '-Fusrc/rpc', '-Fusrc/security', '-Fusrc/lib', '-Fusrc/assets',
        "-Fu$platformUnits", '-Futools/pweb', '-Futest/cap15b',
        '-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
        '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt',
        '-Fudeps/mormot2/src/net', "-Fl$static")
    if ($IsWindows) { $genArgs = @('-Px86_64', '-Twin64') + $genArgs }
    & fpc @genArgs 'test/cap15b/geninc.pas' | Select-Object -Last 2
    if ($LASTEXITCODE -ne 0) { throw 'B2: the descriptor reader (geninc) did not compile' }
    $geninc = Join-Path $bin "geninc$exeSuffix"

    $incDirs = @{}
    $declared = @{}
    foreach ($pair in @(@('release', $relDir), @('dev', $devDir))) {
        $incDir = Join-Path $Work "gen-$($pair[0])"
        Remove-Item -Recurse -Force $incDir -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $incDir | Out-Null
        $out = (& $geninc "--project=$($pair[1])" "--out=$(Join-Path $incDir 'app.network.inc')" 2>&1 | Out-String)
        LocalRequire ($out -match 'refusal ok') "B2: the $($pair[0]) fixture was refused by the descriptor reader"
        $declared[$pair[0]] = if ($out -match 'digest (\S+)') { $Matches[1] } else { '' }
        $incDirs[$pair[0]] = $incDir
    }

    # --- the four images ---------------------------------------------------
    #
    # ON DARWIN THE NETWORKED WITNESS LINKS AN OBJECT, for the CAP-15B
    # reason: both Cocoa adapters are seams over pweb_cocoa_bridge.o. The
    # nonet witness gets none of it, because compiling no transport is the
    # claim it exists to make.
    $macNetLink = @()
    if ($IsMacOS) {
        $bridgeObj = Join-Path $RepoRoot 'build/cap7m/bridge/pweb_cocoa_bridge.o'
        if (-not (Test-Path -LiteralPath $bridgeObj)) {
            throw ("the Cocoa bridge object is absent at $bridgeObj -- " +
                'test/cap15c/build_cap15c.ps1 builds it and runs before these gates')
        }
        $macNetLink = @("-k$bridgeObj", '-k-framework', '-kCocoa',
            '-k-framework', '-kWebKit', '-k-lc++', '-k-lobjc')
    }
    function BuildWitness([string]$Tag, [string]$IncDir, [bool]$Net, [bool]$Plant) {
        $units = Join-Path $Work "units-$Tag"
        $out = Join-Path $Work "bin-$Tag"
        Remove-Item -Recurse -Force $units, $out -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $units, $out | Out-Null
        $a = @('-MObjFPC', '-Sh', '-B', "-FU$units", "-FE$out",
            '-Fusrc/rpc', '-Fusrc/security', '-Fusrc/lib', '-Fusrc/assets',
            "-Fu$platformUnits", '-Futest/cap15c',
            '-Fideps/mormot2/src', '-Fudeps/mormot2/src/core',
            '-Fudeps/mormot2/src/lib', '-Fudeps/mormot2/src/crypt',
            '-Fudeps/mormot2/src/net', "-Fl$static")
        if ($IsWindows) { $a = @('-Px86_64', '-Twin64') + $a }
        if ($Net) { $a += @('-dPWEB_NET', "-Fi$IncDir") + $macNetLink }
        if ($Plant) { $a += '-dCAP15C_PLANT_WS' }
        $a += 'test/cap15c/sockethost.pas'
        & fpc @a | Select-Object -Last 2
        if ($LASTEXITCODE -ne 0) { throw "the $Tag socket witness did not compile" }
        return @{ Exe = Join-Path $out "sockethost$exeSuffix"; Units = $units }
    }
    $rel = BuildWitness 'release' $incDirs['release'] $true $false
    $dev = BuildWitness 'dev' $incDirs['dev'] $true $false
    $twin = BuildWitness 'twin' $incDirs['release'] $true $true
    $none = BuildWitness 'nonet' $incDirs['release'] $false $false

    # --- B2: the door is in the image iff the region was compiled ----------
    $relOut = (& $rel.Exe 2>&1 | Out-String)
    $relExit = $LASTEXITCODE
    LocalRequire ($relExit -eq 0) "B2: the release socket witness exited $relExit"
    $doorLine = $relOut -match 'socket network\.socket pweb\.socketOpen (\d+) open=0'
    LocalRow 'socket_door_available' (LocalBool $doorLine)
    LocalRequire $doorLine 'B2: the release image did not construct the socket door'
    if ($relOut -match 'network (\S+) (\S+)') {
        $same = ($Matches[1] -ceq $declared['release']) -and ($Matches[2] -ceq $declared['release'])
        LocalRow 'socket_allowlist_digest_declared_equals_compiled' (LocalBool $same)
        LocalRequire $same 'B2: the socket witness carries an allowlist other than the declared one'
    } else {
        LocalRow 'socket_allowlist_digest_declared_equals_compiled' 'false'
        LocalRequire $false 'B2: the socket witness printed no digest line'
    }
    $relStrings = ImageStrings $rel.Exe
    $noneStrings = ImageStrings $none.Exe
    foreach ($needle in 'network.socket', 'pweb.socketOpen') {
        LocalRequire ($relStrings.Contains($needle)) "B2: $needle is not in the network image"
        LocalRequire (-not $noneStrings.Contains($needle)) "B2: $needle is in an image that declared no origins"
    }
    LocalRow 'nonet_image_names_socket_door' (LocalBool ($noneStrings.Contains('network.socket') -or $noneStrings.Contains('pweb.socketOpen')))

    # --- B1: the CSP -------------------------------------------------------
    $policySrc = [System.IO.File]::ReadAllText(
        (Join-Path $RepoRoot 'src/security/pweb.navigation.policy.pas'))
    $m = [regex]::Match($policySrc,
        "PWEB_NATIVE_CSP\s*:\s*RawUtf8\s*=\s*((?:\s*'[^']*'\s*\+?)+)\s*;")
    LocalRequire $m.Success 'B1: PWEB_NATIVE_CSP could not be read from the source'
    $csp = (-join ([regex]::Matches($m.Groups[1].Value, "'((?:[^']|'')*)'") |
        ForEach-Object { $_.Groups[1].Value })).Replace("''", "'")
    $cspEverywhere = $true
    foreach ($pair in @(@('release', $relStrings), @('dev', (ImageStrings $dev.Exe)),
                        @('nonet', $noneStrings))) {
        $has = $pair[1].Contains($csp)
        if (-not $has) { $cspEverywhere = $false }
        LocalRequire $has "B1: the $($pair[0]) socket image does not carry PWEB_NATIVE_CSP byte-identically"
    }
    LocalRow 'socket_csp_byte_identical' (LocalBool $cspEverywhere)
    LocalRow 'socket_csp_connect_src' $(if ($csp -match "connect-src 'self'") { 'self' } else { 'MOVED' })
    LocalRequire ($csp -match "connect-src 'self'") 'B1: connect-src is no longer ''self'''

    # --- B3: the ws loopback sweep, and the proof that it fires -----------
    $wsNeedles = @('ws://127.0.0.1', 'ws://localhost', 'ws://[::1]', 'ws://0.0.0.0')
    function SweepWs([string]$Strings) {
        return @($wsNeedles | Where-Object { $Strings.Contains($_) })
    }
    $relHits = SweepWs $relStrings
    $devHits = SweepWs (ImageStrings $dev.Exe)
    $twinHits = SweepWs (ImageStrings $twin.Exe)
    LocalRow 'release_ws_relaxation_literals' ([string]$relHits.Count)
    LocalRow 'dev_image_ws_relaxation_literals' ([string]$devHits.Count)
    LocalRow 'dev_twin_ws_relaxation_literals' ([string]$twinHits.Count)
    LocalRow 'ws_relaxation_sweep_discriminates' (LocalBool (($relHits.Count -eq 0) -and ($twinHits.Count -gt 0)))
    LocalRequire ($relHits.Count -eq 0) "B3: the release image carries a ws loopback literal: $($relHits -join ',')"
    LocalRequire ($devHits.Count -eq 0) ("B3: a development image carries a ws loopback literal " +
        "($($devHits -join ',')) - the door derives it by components and must never spell it")
    LocalRequire ($twinHits.Count -eq 1) ("B3: the planted twin produced $($twinHits.Count) hit(s), " +
        'expected exactly 1 - a negative check whose firing was never observed proves nothing')
    $twinOut = (& $twin.Exe 2>&1 | Out-String)
    LocalRequire ($twinOut -match 'planted ws://127\.0\.0\.1:5173/') 'B3: the planted twin did not run its planted line'

    # --- B4: the compiled unit sets ----------------------------------------
    function HasUnit([string]$UnitDir, [string]$Name) {
        return (Test-Path (Join-Path $UnitDir "$Name.ppu")) -or
               (Test-Path (Join-Path $UnitDir "$Name.o"))
    }
    $wsUnits = @('mormot.net.ws.core', 'mormot.net.ws.client', 'mormot.net.ws.server',
                 'mormot.net.ws.async', 'mormot.net.server', 'mormot.net.async')
    $wsLinked = @()
    foreach ($img in @($rel, $dev, $twin)) {
        foreach ($u in $wsUnits) { if (HasUnit $img.Units $u) { $wsLinked += $u } }
    }
    LocalRow 'mormot_net_ws_files' ([string](@($wsLinked | Select-Object -Unique).Count))
    LocalRequire ($wsLinked.Count -eq 0) "B4: a socket image compiled $(@($wsLinked | Select-Object -Unique) -join ',')"
    LocalRequire (HasUnit $rel.Units 'pweb.rpc.socket') 'B4: the socket decorator is not on the network image unit set'
    if ($IsMacOS) {
        LocalRow 'socket_transport' 'nsurlsession_websocket_task'
        LocalRequire (HasUnit $rel.Units 'pweb.platform.cocoa.socket') 'B4: the Cocoa socket adapter is not on the Darwin unit set'
        LocalRequire (-not (HasUnit $rel.Units 'pweb.rpc.socket.mormot')) 'B4: the mORMot socket transport is on the Darwin unit set'
    } else {
        LocalRow 'socket_transport' 'mormot_net_sock_rfc6455'
        LocalRequire (HasUnit $rel.Units 'pweb.rpc.socket.mormot') 'B4: the socket transport is not on the network image unit set'
        LocalRequire (HasUnit $rel.Units 'mormot.net.sock') 'B4: mormot.net.sock is not on the network image unit set'
    }
    $noneDecorator = HasUnit $none.Units 'pweb.rpc.socket'
    $noneTransport = (HasUnit $none.Units 'pweb.rpc.socket.mormot') -or
        (HasUnit $none.Units 'pweb.platform.cocoa.socket')
    LocalRow 'nonet_links_socket_decorator' (LocalBool $noneDecorator)
    LocalRow 'nonet_links_socket_transport' (LocalBool $noneTransport)
    LocalRequire (-not $noneDecorator) 'B4: a project that declared no origins linked the socket decorator'
    LocalRequire (-not $noneTransport) 'B4: a project that declared no origins linked a socket transport'
}
