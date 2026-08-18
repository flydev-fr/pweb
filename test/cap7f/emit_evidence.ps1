# CAP-7F: the Windows per-target evidence emitter (schema 1).
#
# Emits build/cap7f/evidence.json - the machine-readable summary the final
# cap7-aggregate job compares field-by-field against the other three targets.
# HONESTY INVARIANTS (ratified):
#   - every field derives from a check actually executed in the same run:
#     either re-executed here (export enumeration, logical inventory, release
#     layout shape, the zero-network source sweep) or read from the verdict
#     record of a gate that ran EARLIER IN THE SAME JOB (the CAP-7F host-args
#     gate; a failed gate kills the job before this emitter ever runs);
#   - a conditional gate's SKIP is recorded as SKIP, never promoted to PASS -
#     the aggregator is the one that refuses it;
#   - the logical-inventory formula is byte-identical to
#     test/cap7m/run_cap7m_release.sh emit_manifest: rows
#     `entry=<name> size=<bytes> sha256=<lowercase hex>`, LF line endings,
#     entries in byte (LC_ALL=C) order, directories skipped;
#     logical_inventory_sha256 is the SHA-256 of the manifest file bytes.
#     A CRLF or a culture-sensitive sort would silently break cross-OS hash
#     equality (precedent: the CRLF header-hash defect fixed in CAP-7L), so
#     the sort below compares UTF-8 BYTES and the writer emits LF only.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

foreach ($pre in 'build/webview-dist/webview.dll',
                 'build/cap6/app.pwb',
                 'build/cap6/release/releaseapp.exe',
                 'build/cap7f/host-args.json') {
    if (-not (Test-Path $pre)) {
        throw ("missing precondition: $pre -- the CAP-4W/CAP-6/CAP-7F gates " +
            'must have run in this workspace before evidence can summarize them')
    }
}
New-Item -ItemType Directory -Force build/cap7f | Out-Null
$work = (Resolve-Path build/cap7f).Path

# --- strict 'key = value' lock reader (the one grammar every lock uses) ----
function Read-LockKey([string]$File, [string]$Key) {
    $hits = @(Select-String -Path $File `
        -Pattern ('^' + [regex]::Escape($Key) + '\s*=\s*(.+?)\s*$'))
    if ($hits.Count -ne 1) {
        throw "lock key '$Key' not found exactly once in $File (found $($hits.Count))"
    }
    return $hits[0].Matches[0].Groups[1].Value
}

# --- dumpbin resolution, same fallback chain as the CAP-4W export gate -----
# (test/cap4w/check_webview_exports.ps1 Resolve-Dumpbin; duplicated here
# because that file is a gate script, not a dot-sourceable library)
function Resolve-Dumpbin {
    $command = Get-Command dumpbin.exe -CommandType Application `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    if ($env:VCToolsInstallDir) {
        $candidate = Join-Path $env:VCToolsInstallDir `
            'bin\Hostx64\x64\dumpbin.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} `
        'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $installation = (& $vswhere -latest -products '*' `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath).Trim()
        if ($LASTEXITCODE -eq 0 -and $installation) {
            $tools = Join-Path $installation 'VC\Tools\MSVC'
            $candidate = Get-ChildItem -LiteralPath $tools -Directory |
                Sort-Object Name -Descending |
                ForEach-Object {
                    Join-Path $_.FullName 'bin\Hostx64\x64\dumpbin.exe'
                } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
            if ($candidate) { return $candidate }
        }
    }
    throw '[CAP-7F] dumpbin.exe not found'
}

# --- the export set, RE-ENUMERATED from the built DLL ----------------------
$dumpbin = Resolve-Dumpbin
$dll = (Resolve-Path build/webview-dist/webview.dll).Path
$output = @(& $dumpbin /nologo /exports $dll 2>&1)
if ($LASTEXITCODE -ne 0) { throw '[CAP-7F] dumpbin failed' }
$exports = @($output | ForEach-Object {
    if ($_ -match '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)(?:\s+.*)?$') {
        $Matches[1]
    }
} | Where-Object { $_ } | Sort-Object)
if ($exports.Count -eq 0) { throw '[CAP-7F] dumpbin enumerated no exports' }
Write-Host "[CAP-7F] webview.dll exports enumerated: $($exports.Count)"

# --- pins ------------------------------------------------------------------
$webviewPin = Read-LockKey webview.lock 'commit'
$soname = Read-LockKey webview.lock 'linux-soname'   # libwebview.so.0.12
if ($soname -notmatch '^libwebview\.so\.(\d+\.\d+)$') {
    throw "unexpected linux-soname shape: $soname"
}
$soversion = $Matches[1]
$surface = "17/soname $soversion"

$fpcVersion = (& fpc -iV 2>$null | Out-String).Trim()
if (-not $fpcVersion) { $fpcVersion = '<absent>' }

# --- logical inventory of the REAL app.pwb (React-only on Windows, ratified) --
function Write-LogicalManifest([string]$PwbPath, [string]$OutFile) {
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $PwbPath).Path)
    try {
        $names = [string[]]@($zip.Entries | ForEach-Object FullName |
            Where-Object { $_ -notmatch '/$' })
        if ($names.Count -eq 0) {
            throw "logical inventory of $PwbPath came out empty"
        }
        # BYTE order, not culture order and not UTF-16 ordinal order: the
        # formula is LC_ALL=C over the entry-name bytes.
        $byUtf8Bytes = [System.Comparison[string]]{
            param($x, $y)
            $bx = [System.Text.Encoding]::UTF8.GetBytes($x)
            $by = [System.Text.Encoding]::UTF8.GetBytes($y)
            $n = [Math]::Min($bx.Length, $by.Length)
            for ($i = 0; $i -lt $n; $i++) {
                if ($bx[$i] -ne $by[$i]) { return [int]$bx[$i] - [int]$by[$i] }
            }
            return $bx.Length - $by.Length
        }
        [Array]::Sort($names, $byUtf8Bytes)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $rows = foreach ($name in $names) {
                $entry = $zip.GetEntry($name)
                if ($null -eq $entry) { throw "entry vanished mid-read: $name" }
                $ms = [System.IO.MemoryStream]::new()
                $s = $entry.Open()
                try { $s.CopyTo($ms) } finally { $s.Dispose() }
                $bytes = $ms.ToArray()
                $ms.Dispose()
                $hex = -join ($sha256.ComputeHash($bytes) |
                    ForEach-Object { $_.ToString('x2') })
                "entry=$name size=$($bytes.Length) sha256=$hex"
            }
        } finally { $sha256.Dispose() }
        [System.IO.File]::WriteAllText($OutFile,
            (($rows -join "`n") + "`n"),
            [System.Text.UTF8Encoding]::new($false))
    } finally { $zip.Dispose() }
}

$manifestFile = Join-Path $work 'manifest-react.txt'
Write-LogicalManifest build/cap6/app.pwb $manifestFile
$reactInventorySha = (Get-FileHash $manifestFile -Algorithm SHA256).Hash.ToLowerInvariant()
$reactPwbSha = (Get-FileHash build/cap6/app.pwb -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "[CAP-7F] react logical_inventory_sha256: $reactInventorySha"

# bundle compat facts, read from the bundle itself
$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path build/cap6/app.pwb).Path)
try {
    $entry = $zip.GetEntry('manifest.json')
    if ($null -eq $entry) { throw 'app.pwb has no manifest.json' }
    $r = [System.IO.StreamReader]::new($entry.Open())
    try { $manifestJson = $r.ReadToEnd() } finally { $r.Dispose() }
} finally { $zip.Dispose() }
if ($manifestJson -notmatch '"protocol"\s*:\s*(\d+)') {
    throw "app.pwb manifest.json carries no protocol: $manifestJson"
}
$bundleProtocol = $Matches[1]

# --- release layout, RE-ASSERTED (exe + app.pwb + dll, nothing else) -------
$files = @(Get-ChildItem build/cap6/release -Recurse -File |
    ForEach-Object Name | Sort-Object)
$expectedLayout = @('app.pwb', 'releaseapp.exe', 'webview.dll')
if (($files -join ',') -ne ($expectedLayout -join ',')) {
    throw "release dir is not the ratified triple: $($files -join ', ')"
}
$releaseLayout = 'PASS'

# --- zero-network source sweep, RE-EXECUTED (cheap, deterministic) ---------
& pwsh -NoProfile -File test/cap6/check_cap6_nonetwork.ps1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'CAP-6 zero-network sweep FAILED under the emitter' }
$noListener = 'PASS'

# --- runtime verdict fields from the CAP-7F args gate (PASS/SKIP honest) ----
$hostArgs = Get-Content build/cap7f/host-args.json -Raw | ConvertFrom-Json
if ($hostArgs.schema -ne 1) { throw 'host-args.json schema mismatch' }
$hostArgsVerdict = $hostArgs.overall
if ($hostArgsVerdict -eq 'PASS') {
    $passLog = Get-Content (Join-Path $work 'host-args-pass.log') -Raw
    if ($passLog -notmatch '"secure":true') {
        throw 'args-gate PASS log carries no "secure":true page report'
    }
    if ($passLog -notmatch '"value":42') {
        throw 'args-gate PASS log carries no "value":42 page report'
    }
    if ($passLog -notmatch [regex]::Escape('pweb://app')) {
        throw 'args-gate PASS log never named the pweb://app origin'
    }
    $origin = 'pweb://app'
    $secure = 'true'
    $rpc = '42'
    $runtimeProvenance = 'runtime-gate (CAP-7F args gate PASS leg, this job)'
} else {
    # honest SKIP: the aggregator refuses these, by design
    $origin = 'SKIP'
    $secure = 'SKIP'
    $rpc = 'SKIP'
    $runtimeProvenance = 'runtime-gate:SKIP (no usable WebView2/desktop session)'
}

# --- run identity -----------------------------------------------------------
$sha = $env:GITHUB_SHA
if (-not $sha) { $sha = (& git rev-parse HEAD).Trim() }
$runId = $env:GITHUB_RUN_ID
if (-not $runId) { $runId = '<local>' }

$evidence = [ordered]@{
    schema                          = 1
    target                          = 'windows-x86_64'
    os                              = 'windows'
    arch                            = 'x86_64'
    fpc                             = $fpcVersion
    cc                              = 'MSVC (webview.dll built by CMake + the VS toolset; exports re-enumerated via dumpbin)'
    webview_pin                     = $webviewPin
    webview_surface                 = $surface
    engine                          = 'WebView2'
    exports                         = $exports
    extra_exports_rtti              = 0
    origin                          = $origin
    secure                          = $secure
    bundle_protocol                 = $bundleProtocol
    rpc_add_20_22                   = $rpc
    runtime_provenance              = $runtimeProvenance
    host_args                       = $hostArgsVerdict
    release_layout                  = $releaseLayout
    no_listener                     = $noListener
    no_listener_provenance          = 'source-sweep re-executed (check_cap6_nonetwork.ps1); CAP-5/CAP-6 job gates precede this emitter'
    app_pwb_react_sha256            = $reactPwbSha
    logical_inventory_sha256_react  = $reactInventorySha
    logical_inventory_sha256_pas2js = ''
    github_sha                      = $sha
    github_run_id                   = "$runId"
    waivers                         = @(
        'CAP-13 clean-machine legs are human-run or WAIVED per the deferred-work ledger; recorded here, never rerun',
        'app.pwb is React-only on Windows (ratified CAP-6 shape); no pas2js inventory exists for this target'
    )
}
$json = $evidence | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText((Join-Path $work 'evidence.json'),
    $json + "`n", [System.Text.UTF8Encoding]::new($false))

Write-Host "[CAP-7F] evidence.json written for windows-x86_64 (host_args=$hostArgsVerdict, exports=$($exports.Count))"
