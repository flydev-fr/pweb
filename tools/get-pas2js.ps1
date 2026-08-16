# Fetches the pinned Pas2JS release into deps/pas2js (git-ignored).
# The pin lives in pas2js.lock at the repo root. The archive is verified
# against the recorded sha256 BEFORE extraction; any mismatch aborts, so
# an upstream re-roll of the archive can never silently change the
# toolchain. The compiler binary and its RTL come from this checkout only
# -- never from a host-installed Lazarus/FPC pas2js.
#
# CAP-7L makes the BUILD HOST a variable, never the pinned version: the
# Linux host fetches the linux-* artifact of the same Pas2JS 3.0.1 into
# deps/pas2js-linux, so a dev machine sharing one working tree between
# Windows and WSL can hold both toolchains without either clobbering the
# other. The frontend sources, the SDK and the compiler version are
# identical on both, which is what makes the Linux runtime gate a parity
# proof rather than a second frontend path.
#
# CAP-7M2 adds the Darwin hosts (deps/pas2js-darwin), and one of them is
# not a fetch: upstream ships Pas2JS 3.0.1 for Darwin as a thin x86_64
# binary ONLY, and Rosetta is banned, so on arm64 the SAME pinned logical
# version is compiled natively from the pinned FPC repository revision
# whose pastojs IS 3.0.1 (see pas2js.lock). On Darwin the staged compiler
# is additionally asserted to be a Mach-O of the HOST architecture via
# `lipo -archs` BEFORE it is ever executed - executing a wrong-arch binary
# is exactly the silent-Rosetta path this pin exists to exclude, so an arch
# drift dies here, at fetch, not mid-gate.
#
# Usage: pwsh tools/get-pas2js.ps1 [-Force]

param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LockFile = Join-Path $RepoRoot 'pas2js.lock'
$DepsDir  = Join-Path $RepoRoot 'deps'

# Deliberately not $IsWindows: that automatic variable does not exist in
# Windows PowerShell 5.1, where it would read as $false and silently pick
# the Linux artifact. Off Windows the split is on `uname -s`, which every
# POSIX host answers, rather than on $IsMacOS for the same 5.1 reason.
$OnWindows = ($env:OS -eq 'Windows_NT')
$OnDarwin = $false
$HostArch = ''
if (-not $OnWindows) {
    $OnDarwin = ((& uname -s | Out-String).Trim() -eq 'Darwin')
}
if ($OnWindows) {
    $Target = Join-Path $DepsDir 'pas2js'
    $UrlKey = 'url'
    $ShaKey = 'sha256'
    $RootKey = 'rootdir'
    $BinRelative = 'bin/pas2js.exe'
}
elseif ($OnDarwin) {
    $Target = Join-Path $DepsDir 'pas2js-darwin'
    $UrlKey = 'darwin-url'
    $ShaKey = 'darwin-sha256'
    $RootKey = 'darwin-rootdir'
    $BinRelative = 'bin/pas2js'
    # `uname -m` and `lipo -archs` agree on the slice names ('x86_64',
    # 'arm64'), which is what makes the arch assertions below one equality.
    $HostArch = (& uname -m | Out-String).Trim()
    if ($HostArch -notin @('x86_64', 'arm64')) {
        throw "unsupported Darwin host architecture '$HostArch'"
    }
}
else {
    $Target = Join-Path $DepsDir 'pas2js-linux'
    $UrlKey = 'linux-url'
    $ShaKey = 'linux-sha256'
    $RootKey = 'linux-rootdir'
    $BinRelative = 'bin/pas2js'
}

# --- read the lock (strict: any malformed line is an error) -------------------
$Lock = @{}
$LineNo = 0
foreach ($line in Get-Content $LockFile) {
    $LineNo++
    $line = $line.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    if ($line -notmatch '=') {
        throw "pas2js.lock line ${LineNo}: malformed (expected 'key = value'): $line"
    }
    $k, $v = $line -split '=', 2
    $Lock[$k.Trim()] = $v.Trim()
}

foreach ($key in 'version', $UrlKey, $ShaKey, $RootKey) {
    if (-not $Lock[$key]) { throw "pas2js.lock: '$key' is required" }
}
if ($Lock[$ShaKey] -notmatch '^[0-9a-f]{64}$') {
    throw "pas2js.lock: $ShaKey '$($Lock[$ShaKey])' is not a 64-char hex digest"
}
if ($OnDarwin -and $HostArch -eq 'arm64') {
    foreach ($key in 'darwin-arm64-source-url', 'darwin-arm64-source-commit') {
        if (-not $Lock[$key]) { throw "pas2js.lock: '$key' is required on aarch64-darwin" }
    }
    if ($Lock['darwin-arm64-source-commit'] -notmatch '^[0-9a-f]{40}$') {
        throw "pas2js.lock: darwin-arm64-source-commit is not a full 40-char SHA"
    }
}

$Compiler = Join-Path $Target $BinRelative

# On Darwin the compiler's Mach-O architecture is read BEFORE the binary is
# ever executed: running a wrong-arch cached binary would either fail with a
# CPU-type error or - worse - run under Rosetta and satisfy the version check
# from a translated process. Wrong arch is 'unusable cache', never 'usable'.
function Get-DarwinSlices([string]$Path) {
    $slices = ''
    try { $slices = (& lipo -archs $Path 2>$null | Out-String).Trim() } catch {}
    return $slices
}

if ((Test-Path $Target) -and $Force) { Remove-Item -Recurse -Force $Target }

if (Test-Path $Compiler) {
    # a corrupt cached binary must fall through to a refetch, not abort
    $CacheUsable = $true
    if ($OnDarwin) {
        $Slices = Get-DarwinSlices $Compiler
        if ($Slices -ne $HostArch) {
            $CacheUsable = $false
            Write-Host "pas2js cache carries slices '$Slices', host is '$HostArch': refetching (a wrong-arch binary must never run)"
        }
    }
    if ($CacheUsable) {
        $Have = ''
        try { $Have = (& $Compiler -iV 2>$null | Out-String).Trim() } catch {}
        if ($Have -eq $Lock['version']) {
            Write-Host "pas2js $Have already present at $Target"
            exit 0
        }
        Write-Host "pas2js cache unusable or version drift ('$Have' != '$($Lock['version'])'): refetching"
    }
    Remove-Item -Recurse -Force $Target
}
if (Test-Path $Target) {
    # partial earlier install (no compiler): clear it so Move-Item below
    # never nests the fresh tree inside a stale directory
    Remove-Item -Recurse -Force $Target
}

New-Item -ItemType Directory -Force $DepsDir | Out-Null
$Zip = Join-Path $DepsDir 'pas2js-download.zip'
if (Test-Path $Zip) { Remove-Item -Force $Zip }

Write-Host "fetching $($Lock[$UrlKey])"
Invoke-WebRequest -Uri $Lock[$UrlKey] -OutFile $Zip -UseBasicParsing

$Actual = (Get-FileHash -Algorithm SHA256 -Path $Zip).Hash.ToLowerInvariant()
if ($Actual -ne $Lock[$ShaKey]) {
    Remove-Item -Force $Zip
    throw ("pas2js archive sha256 mismatch: expected $($Lock[$ShaKey])," +
        " got $Actual -- upstream changed; ratify a new pin deliberately")
}

$Staging = Join-Path $DepsDir 'pas2js-staging'
if (Test-Path $Staging) { Remove-Item -Recurse -Force $Staging }
Expand-Archive -Path $Zip -DestinationPath $Staging
Remove-Item -Force $Zip

$Root = Join-Path $Staging $Lock[$RootKey]
if (-not (Test-Path (Join-Path $Root $BinRelative))) {
    throw "pas2js archive layout unexpected: no $($Lock[$RootKey])/$BinRelative"
}
Move-Item -Path $Root -Destination $Target
Remove-Item -Recurse -Force $Staging

if ($OnDarwin -and $HostArch -eq 'arm64') {
    # ---- CAP-7M2: aarch64-darwin has NO upstream binary of Pas2JS 3.0.1 ----
    # The zip just extracted supplies the RTL packages/ and pas2js.cfg, which
    # are host-independent and stay byte-untouched; its bin/pas2js is a thin
    # x86_64 Mach-O (measured), which on this host could only ever run under
    # Rosetta - banned. So that binary is DELETED before anything can execute
    # it, and the SAME pinned logical version is compiled natively from the
    # FPC repository at the exact pinned commit (the pas2js/fixes_3_0 head,
    # whose pastojs IS 3.0.1). Fetched by SHA, never by branch or tag,
    # exactly like deps/webview.
    Remove-Item -Force $Compiler

    $SrcUrl = $Lock['darwin-arm64-source-url']
    $SrcCommit = $Lock['darwin-arm64-source-commit']
    $Src = Join-Path $DepsDir 'pas2js-fpc-src'
    if (-not (Test-Path (Join-Path $Src '.git'))) {
        New-Item -ItemType Directory -Force $Src | Out-Null
        git -C $Src init --quiet
        git -C $Src remote add origin $SrcUrl
    }
    else {
        # keep the remote in sync with the lock so a URL change is never ignored
        git -C $Src remote set-url origin $SrcUrl
        if ($LASTEXITCODE -ne 0) { throw 'git remote set-url failed' }
    }
    $Current = git -C $Src rev-parse --verify --quiet HEAD
    if ($Current -ne $SrcCommit) {
        # Fetch only the pinned commit. No branch names, no tags, no HEAD.
        git -C $Src fetch --quiet --depth 1 origin $SrcCommit
        if ($LASTEXITCODE -ne 0) { throw "git fetch of pinned SHA $SrcCommit failed" }
        git -C $Src -c advice.detachedHead=false checkout --quiet --force $SrcCommit
        if ($LASTEXITCODE -ne 0) { throw "git checkout of pinned SHA $SrcCommit failed" }
    }
    $Head = git -C $Src rev-parse HEAD
    if ($Head -ne $SrcCommit) { throw "checkout mismatch: HEAD=$Head expected=$SrcCommit" }

    $Pas2jsMain = Join-Path $Src 'utils/pas2js/pas2js.pp'
    if (-not (Test-Path $Pas2jsMain)) {
        throw "pinned FPC source has no utils/pas2js/pas2js.pp at $SrcCommit"
    }

    # The compiler doing the compiling must be the PINNED FPC, not whatever
    # is first on PATH: a drifted toolchain could still produce a binary
    # that reports 3.0.1, and the -iV check below it would never notice.
    # Strict read of fpc.lock's 'version' key, exact equality, die naming
    # both values.
    $FpcLockFile = Join-Path $RepoRoot 'fpc.lock'
    $FpcWant = ''
    $FpcLineNo = 0
    foreach ($line in Get-Content $FpcLockFile) {
        $FpcLineNo++
        $line = $line.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '=') {
            throw "fpc.lock line ${FpcLineNo}: malformed (expected 'key = value'): $line"
        }
        $k, $v = $line -split '=', 2
        if ($k.Trim() -eq 'version') {
            if ($FpcWant) { throw "fpc.lock contains duplicate key 'version'" }
            $FpcWant = $v.Trim()
        }
    }
    if (-not $FpcWant) { throw "fpc.lock has no 'version' entry" }
    $FpcHave = (& fpc -iV | Out-String).Trim()
    if ($FpcHave -ne $FpcWant) {
        throw ("fpc on PATH reports '$FpcHave' but fpc.lock pins '$FpcWant'" +
            ' -- the native pas2js compile must use the pinned FPC')
    }

    # Natively, with the pinned FPC just asserted (selected on PATH by
    # tools/get-fpc-macos.ps1). The unit paths are the pastojs compiler and
    # the three fcl package sources it is built from; a missing unit fails
    # THIS step loudly, which is the ratified failure point (at fetch, not
    # mid-gate).
    Write-Host "compiling pas2js $($Lock['version']) natively from FPC source @ $SrcCommit"
    $Units = Join-Path $Src 'build-pas2js-units'
    if (Test-Path $Units) { Remove-Item -Recurse -Force $Units }
    New-Item -ItemType Directory -Force $Units | Out-Null
    $FpcArgs = @(
        '-MObjFPC', '-Sh', '-O2', '-B',
        ('-FU' + $Units),
        ('-Fu' + (Join-Path $Src 'packages/pastojs/src')),
        ('-Fu' + (Join-Path $Src 'packages/fcl-passrc/src')),
        ('-Fu' + (Join-Path $Src 'packages/fcl-js/src')),
        ('-Fu' + (Join-Path $Src 'packages/fcl-json/src')),
        ('-Fi' + (Join-Path $Src 'packages/pastojs/src')),
        ('-Fi' + (Join-Path $Src 'utils/pas2js')),
        ('-o' + $Compiler),
        $Pas2jsMain
    )
    & fpc @FpcArgs
    if ($LASTEXITCODE -ne 0) { throw 'native aarch64-darwin pas2js compile FAILED' }
    if (-not (Test-Path $Compiler)) {
        throw "native pas2js compile produced no binary at $Compiler"
    }
    Remove-Item -Recurse -Force $Units
}

if (-not $OnWindows) {
    # Expand-Archive does not carry the POSIX mode bits out of a zip, so
    # the freshly extracted compiler is not executable yet (the natively
    # compiled arm64 one already is; chmod is idempotent there)
    & chmod +x $Compiler
    if ($LASTEXITCODE -ne 0) {
        throw "unable to mark the pas2js compiler executable: $Compiler"
    }
}

if ($OnDarwin) {
    # The arch assertion runs BEFORE -iV, i.e. before the binary is executed
    # at all: a wrong-arch compiler answering the version probe would already
    # be Rosetta in action.
    $Slices = Get-DarwinSlices $Compiler
    if ($Slices -ne $HostArch) {
        throw ("staged pas2js compiler carries slices '$Slices', host is '$HostArch'" +
            ' -- a wrong-arch binary could only run under Rosetta, which is banned')
    }
}

$Have = (& $Compiler -iV).Trim()
if ($Have -ne $Lock['version']) {
    throw "fetched pas2js reports version '$Have', lock pins '$($Lock['version'])'"
}
foreach ($rtl in 'packages/rtl/src/system.pas', 'packages/rtl/src/js.pas',
                 'packages/rtl/src/rtl.js') {
    if (-not (Test-Path (Join-Path $Target $rtl))) {
        throw "pas2js RTL incomplete: missing $rtl"
    }
}
Write-Host "pas2js $Have ready at $Target"
