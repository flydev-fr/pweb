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

# The CAP-9C2 semantic gate names, in ONE place: the two emitters and the
# aggregator's negative self-test all read this list, so a gate cannot be
# added to the corpus and forgotten by the thing that refuses it.
$CAP9C2_GATE_FIELDS = @(
    'ui_rendered', 'ui_add', 'quickjs_add', 'reporting_code',
    'reporting_soa_count', 'reporting_denied_bridge', 'opener_reached',
    'same_scheduler', 'same_policy', 'same_bridge', 'same_server',
    'browser_plugin_store_arrivals', 'quickjs_app_store_arrivals',
    'browser_plugin_script_marker', 'raw_channel_source_bytes',
    'quickjs_window_absent', 'quickjs_document_absent',
    'quickjs_webkit_channel_absent', 'quickjs_webview2_channel_absent',
    'quickjs_raw_webview_invoke_absent', 'concurrent_overlap',
    'no_cross_delivery', 'plugin_archive_verified',
    'plugin_inventory_verified', 'neighbour_survived_timeout',
    'ui_survived_timeout', 'reload_generation_changed', 'clean_shutdown',
    'release_layout', 'hostile_running', 'hostile_failed'
)

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

# fpc must exist and answer: an '<absent>' placeholder would compare EQUAL
# across targets that are all missing the compiler, which is exactly the
# false agreement the aggregator exists to refuse
if (-not (Get-Command fpc -ErrorAction SilentlyContinue)) {
    throw '[CAP-7F] fpc not found on PATH -- the toolchain evidence cannot be emitted'
}
$fpcVersion = (& fpc -iV | Out-String).Trim()
if (-not $fpcVersion) { throw '[CAP-7F] fpc -iV answered nothing' }

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
# -Force so a hidden file breaks the exact-set claim, parity with `ls -A`
$files = @(Get-ChildItem build/cap6/release -Recurse -File -Force |
    ForEach-Object Name | Sort-Object)
$expectedLayout = @('app.pwb', 'releaseapp.exe', 'webview.dll')
if (($files -join ',') -ne ($expectedLayout -join ',')) {
    throw "release dir is not the ratified triple: $($files -join ', ')"
}
# the SHIPPED bytes are the MEASURED bytes: the inventory below is taken
# from build/cap6/app.pwb and the export set from build/webview-dist, so
# both must be byte-identical to what the release dir actually ships
foreach ($pair in @(
    @{ A = 'build/cap6/app.pwb'; B = 'build/cap6/release/app.pwb' },
    @{ A = 'build/webview-dist/webview.dll'; B = 'build/cap6/release/webview.dll' })) {
    $ha = (Get-FileHash $pair.A -Algorithm SHA256).Hash
    $hb = (Get-FileHash $pair.B -Algorithm SHA256).Hash
    if ($ha -cne $hb) {
        throw "shipped bytes differ from measured bytes: $($pair.A) ($ha) vs $($pair.B) ($hb)"
    }
}
$releaseLayout = 'PASS'

# --- zero-network source sweep, RE-EXECUTED (cheap, deterministic) ---------
$sweepOut = & pwsh -NoProfile -File test/cap6/check_cap6_nonetwork.ps1 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host $sweepOut
    throw 'CAP-6 zero-network sweep FAILED under the emitter'
}
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
    if ($passLog -notmatch '"value":42([^0-9]|$)') {
        throw 'args-gate PASS log carries no anchored "value":42 page report'
    }
    if ($passLog -notmatch [regex]::Escape('pweb://app')) {
        throw 'args-gate PASS log never named the pweb://app origin'
    }
    # CAP-8A runtime deny enforcement, re-asserted at evidence time: an
    # allow-all regression reports "denied":false (the unmapped probe
    # 404s instead of being forbidden) and must never emit evidence
    if ($passLog -notmatch '"denied":true') {
        throw 'args-gate PASS log carries no "denied":true page report -- the production policy did not forbid the unmapped probe'
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

# --- CAP-8A capability-policy verdict + decision digest ---------------------
# capability-policy.txt is written by the pwebtests CAP-8A suite that ran
# EARLIER IN THIS JOB (a failed suite kills the job before this emitter,
# and CI checks out fresh so no stale file can survive a previous run);
# its sha256 is the cross-target policy-decision digest the aggregator
# requires to be identical on all four targets. The file's own trailing
# verdict line is required too - honesty, not step order alone.
$capPolicyFile = Join-Path $work 'capability-policy.txt'
if (-not (Test-Path $capPolicyFile)) {
    throw '[CAP-7F] capability-policy.txt missing -- the CAP-8A pwebtests suite has not run in this workspace'
}
$capLines = @(Get-Content $capPolicyFile)
if ($capLines.Count -lt 2) {
    # guarded BEFORE any index: an empty or one-line corpus must produce
    # this diagnosis, never a StrictMode index/null error
    throw "[CAP-7F] capability-policy.txt is empty or truncated ($($capLines.Count) line(s)) -- the CAP-8A suite did not write a full corpus"
}
if ($capLines[0] -cne 'schema=1') {
    throw '[CAP-7F] capability-policy.txt carries no schema=1 header'
}
if ($capLines[-1] -cne 'verdict=PASS') {
    throw '[CAP-7F] capability-policy.txt does not end in verdict=PASS'
}
$capabilityPolicy = 'PASS'
$capabilityPolicyDigest = (Get-FileHash $capPolicyFile -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "[CAP-7F] capability_policy_digest: $capabilityPolicyDigest"

# --- CAP-8B navigation-security verdict + navigation-decision digest ---------
# navigation-policy.txt is written by the pwebtests CAP-8B suite that ran
# EARLIER IN THIS JOB (a stale copy is removed before that suite, and CI
# checks out fresh); its sha256 is the cross-target navigation-decision digest
# the aggregator requires to be identical on all four targets, because every
# line is a pure decision of a pure function. The file's own trailing verdict
# line is required too - honesty, not step order alone.
$navPolicyFile = Join-Path $work 'navigation-policy.txt'
if (-not (Test-Path $navPolicyFile)) {
    throw '[CAP-7F] navigation-policy.txt missing -- the CAP-8B pwebtests suite has not run in this workspace'
}
$navLines = @(Get-Content $navPolicyFile)
if ($navLines.Count -lt 2) {
    throw "[CAP-7F] navigation-policy.txt is empty or truncated ($($navLines.Count) line(s)) -- the CAP-8B suite did not write a full corpus"
}
if ($navLines[0] -cne 'schema=1') {
    throw '[CAP-7F] navigation-policy.txt carries no schema=1 header'
}
if ($navLines[-1] -cne 'verdict=PASS') {
    throw '[CAP-7F] navigation-policy.txt does not end in verdict=PASS'
}
$navigationPolicyDigest = (Get-FileHash $navPolicyFile -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "[CAP-7F] navigation_policy_digest: $navigationPolicyDigest"

# navigation_security: the real-window matrix verdict, read from the record
# test/cap8b/run_nav_matrix.ps1 wrote earlier in this job. PASS gates; an
# honest SKIP (no WebView2/desktop session) is recorded as SKIP and the
# aggregator REFUSES it, exactly as it does host_args.
# the gate writes into ITS workspace (build/cap8b), not this emitter's
$navMatrixFile = Join-Path $repoRoot 'build/cap8b/nav-matrix.json'
if (-not (Test-Path $navMatrixFile)) {
    throw '[CAP-7F] nav-matrix.json missing -- the CAP-8B nav-matrix gate has not run in this workspace'
}
$navMatrix = Get-Content $navMatrixFile -Raw | ConvertFrom-Json
if ($navMatrix.schema -ne 1) { throw '[CAP-7F] nav-matrix.json schema mismatch' }
$navigationSecurity = "$($navMatrix.overall)"
if ($navigationSecurity -notin @('PASS', 'FAIL', 'SKIP')) {
    throw "[CAP-7F] nav-matrix.json carries an unexpected verdict: $navigationSecurity"
}
Write-Host "[CAP-7F] navigation_security: $navigationSecurity"

# --- CAP-8C multi-principal security corpus + one canonical digest ----------
# The harness record is read FIRST and its overall verdict recorded VERBATIM
# (PASS|FAIL|SKIP) - exactly the navigation_security shape: an honest FAIL or
# SKIP goes into the evidence and the AGGREGATOR refuses it; the emitter never
# throws a FAIL into oblivion where no evidence would name it.
$mpFile = Join-Path $repoRoot 'build/cap8c/multiprincipal-windows-x86_64.json'
if (-not (Test-Path $mpFile)) {
    throw '[CAP-7F] multiprincipal-windows-x86_64.json missing -- the CAP-8C gate has not run in this workspace'
}
$mp = Get-Content $mpFile -Raw | ConvertFrom-Json
if ($mp.schema -ne 1) { throw '[CAP-7F] multiprincipal json schema mismatch' }
$securityCorpus = "$($mp.overall)"
if ($securityCorpus -notin @('PASS', 'FAIL', 'SKIP')) {
    throw "[CAP-7F] multiprincipal json carries an unexpected verdict: $securityCorpus"
}

# the defense-in-depth counters are REQUIRED whenever the harness actually
# ran (PASS or FAIL): an absent property must THROW, never coerce to a silent
# 0 - a renamed harness field would otherwise turn these into constant zeroes
# (fail-open). Only the runner-synthesized SKIP record may omit them.
function Read-MpCounter([object]$Record, [string]$Name) {
    $p = $Record.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value -or "$($p.Value)" -eq '') {
        throw "[CAP-7F] multiprincipal record carries no '$Name' counter -- refusing to default it to 0"
    }
    return [int]$p.Value
}
if ($securityCorpus -ne 'SKIP') {
    $cap8cDeniedSoa = (Read-MpCounter $mp 'denied_bridge_login_add') +
        (Read-MpCounter $mp 'denied_bridge_plugin_add')
    $cap8cOpenerNonMain = (Read-MpCounter $mp 'opener_login') +
        (Read-MpCounter $mp 'opener_plugin') +
        (Read-MpCounter $mp 'opener_unexpected')
    $so = $mp.PSObject.Properties['secure_origin']
    if ($null -eq $so) {
        throw "[CAP-7F] multiprincipal record carries no 'secure_origin' field -- refusing to default it"
    }
    if ($so.Value) { $cap8cSecureOrigin = 'true' } else { $cap8cSecureOrigin = 'false' }
} else {
    # honest SKIP shape (no WebView2/desktop session): the aggregator's
    # mustPass refusal of the SKIP verdict is the one signal; these values
    # are recorded but never consulted for a non-PASS corpus
    $cap8cDeniedSoa = 0
    $cap8cOpenerNonMain = 0
    $cap8cSecureOrigin = 'false'
}

# security-corpus.txt is the CANONICAL decision/counter corpus (headless
# native leg + measured GUI facts): identical bytes on all four targets by
# construction, so its sha256 is the cross-target digest. Its verdict=PASS
# trailer is required ONLY when overall=PASS - an honest FAIL/SKIP corpus
# carries its own verdict line and is refused by the aggregator through the
# verdict field, never silently normalized here.
$corpusFile = Join-Path $repoRoot 'build/cap8c/security-corpus.txt'
if ($securityCorpus -ceq 'PASS') {
    if (-not (Test-Path $corpusFile)) {
        throw '[CAP-7F] security-corpus.txt missing while the harness records PASS'
    }
    $corpusRows = @(Get-Content $corpusFile)
    if ($corpusRows.Count -lt 2) {
        throw "[CAP-7F] security-corpus.txt is empty or truncated ($($corpusRows.Count) line(s))"
    }
    if ($corpusRows[0] -cne 'schema=1') {
        throw '[CAP-7F] security-corpus.txt carries no schema=1 header'
    }
    if ($corpusRows[-1] -cne 'verdict=PASS') {
        throw '[CAP-7F] security-corpus.txt does not end in verdict=PASS while the harness records PASS'
    }
    $securityCorpusDigest = (Get-FileHash $corpusFile -Algorithm SHA256).Hash.ToLowerInvariant()
} elseif (Test-Path $corpusFile) {
    $securityCorpusDigest = (Get-FileHash $corpusFile -Algorithm SHA256).Hash.ToLowerInvariant()
} else {
    $securityCorpusDigest = 'ABSENT'
}
Write-Host "[CAP-7F] security_corpus_digest: $securityCorpusDigest"
Write-Host "[CAP-7F] security_corpus: $securityCorpus (denied_soa=$cap8cDeniedSoa opener_nonmain=$cap8cOpenerNonMain secure=$cap8cSecureOrigin)"

# --- CAP-9A QuickJS invocation-foundation corpus + one canonical digest -----
# Same honesty shape as the CAP-8C block: the harness record's verdict is
# recorded VERBATIM (PASS|FAIL - the harness is fully headless and never
# SKIPs), the defense-in-depth counters are REQUIRED (an absent property
# throws, never coerces to a fail-open 0), and the corpus digest is the
# sha256 of build/cap9a/quickjs-corpus.txt, identical on all four targets
# by construction.
$qfFile = Join-Path $repoRoot 'build/cap9a/quickjsfoundation-windows-x86_64.json'
if (-not (Test-Path $qfFile)) {
    throw '[CAP-7F] quickjsfoundation-windows-x86_64.json missing -- the CAP-9A gate has not run in this workspace'
}
$qf = Get-Content $qfFile -Raw | ConvertFrom-Json
if ($qf.schema -ne 1) { throw '[CAP-7F] quickjsfoundation json schema mismatch' }
$quickjsCorpus = "$($qf.overall)"
if ($quickjsCorpus -notin @('PASS', 'FAIL')) {
    throw "[CAP-7F] quickjsfoundation json carries an unexpected verdict: $quickjsCorpus"
}
$cap9aDeniedBridge = Read-MpCounter $qf 'denied_bridge_add'
$cap9aOpenerReached = Read-MpCounter $qf 'opener_reached'

$qfCorpusFile = Join-Path $repoRoot 'build/cap9a/quickjs-corpus.txt'
if ($quickjsCorpus -ceq 'PASS') {
    if (-not (Test-Path $qfCorpusFile)) {
        throw '[CAP-7F] quickjs-corpus.txt missing while the harness records PASS'
    }
    $qfRows = @(Get-Content $qfCorpusFile)
    if ($qfRows.Count -lt 2) {
        throw "[CAP-7F] quickjs-corpus.txt is empty or truncated ($($qfRows.Count) line(s))"
    }
    if ($qfRows[0] -cne 'schema=1') {
        throw '[CAP-7F] quickjs-corpus.txt carries no schema=1 header'
    }
    if ($qfRows[-1] -cne 'verdict=PASS') {
        throw '[CAP-7F] quickjs-corpus.txt does not end in verdict=PASS while the harness records PASS'
    }
    $quickjsCorpusDigest = (Get-FileHash $qfCorpusFile -Algorithm SHA256).Hash.ToLowerInvariant()
} elseif (Test-Path $qfCorpusFile) {
    $quickjsCorpusDigest = (Get-FileHash $qfCorpusFile -Algorithm SHA256).Hash.ToLowerInvariant()
} else {
    $quickjsCorpusDigest = 'ABSENT'
}
Write-Host "[CAP-7F] quickjs_corpus_digest: $quickjsCorpusDigest"
Write-Host "[CAP-7F] quickjs_corpus: $quickjsCorpus (denied_bridge=$cap9aDeniedBridge opener_reached=$cap9aOpenerReached)"

# --- CAP-9B1 QuickJS package/module-loader corpus + one canonical digest ----
# Identical honesty shape to the CAP-9A block above: the harness is fully
# headless and never SKIPs, the counters are REQUIRED (an absent property
# throws rather than coercing to a fail-open 0), and the digest is the
# sha256 of build/cap9b1/quickjs-package-corpus.txt, which is identical on
# all four targets by construction (every fixture is generated in-process
# from byte constants, so no checkout can change what is hashed).
$qpFile = Join-Path $repoRoot 'build/cap9b1/quickjspackage-windows-x86_64.json'
if (-not (Test-Path $qpFile)) {
    throw '[CAP-7F] quickjspackage-windows-x86_64.json missing -- the CAP-9B1 gate has not run in this workspace'
}
$qp = Get-Content $qpFile -Raw | ConvertFrom-Json
if ($qp.schema -ne 1) { throw '[CAP-7F] quickjspackage json schema mismatch' }
$quickjsPackageCorpus = "$($qp.overall)"
if ($quickjsPackageCorpus -notin @('PASS', 'FAIL')) {
    throw "[CAP-7F] quickjspackage json carries an unexpected verdict: $quickjsPackageCorpus"
}
$cap9b1LoadTimeBridge = Read-MpCounter $qp 'loadtime_bridge'
$cap9b1LoaderWrongThread = Read-MpCounter $qp 'loader_wrong_thread'
$cap9b1StoreWrongThread = Read-MpCounter $qp 'store_wrong_thread'
$cap9b1DeniedBridge = Read-MpCounter $qp 'denied_bridge_add'
# promoted so the AGGREGATE can cross-check them, not only the harness's
# own verdict: a failed load that left a queueable source, or a plugin
# that reached the openExternal bridge arm, are exactly the invariants a
# defense-in-depth counter exists to let a second reader refuse
$cap9b1SourceOpen = Read-MpCounter $qp 'source_open_after_failure'
$cap9b1OpenerReached = Read-MpCounter $qp 'opener_reached'

$qpCorpusFile = Join-Path $repoRoot 'build/cap9b1/quickjs-package-corpus.txt'
if ($quickjsPackageCorpus -ceq 'PASS') {
    if (-not (Test-Path $qpCorpusFile)) {
        throw '[CAP-7F] quickjs-package-corpus.txt missing while the harness records PASS'
    }
    $qpRows = @(Get-Content $qpCorpusFile)
    if ($qpRows.Count -lt 2) {
        throw "[CAP-7F] quickjs-package-corpus.txt is empty or truncated ($($qpRows.Count) line(s))"
    }
    if ($qpRows[0] -cne 'schema=1') {
        throw '[CAP-7F] quickjs-package-corpus.txt carries no schema=1 header'
    }
    if ($qpRows[-1] -cne 'verdict=PASS') {
        throw '[CAP-7F] quickjs-package-corpus.txt does not end in verdict=PASS while the harness records PASS'
    }
    $quickjsPackageDigest = (Get-FileHash $qpCorpusFile -Algorithm SHA256).Hash.ToLowerInvariant()
} elseif (Test-Path $qpCorpusFile) {
    # the FAIL direction matters too: a corpus still carrying verdict=PASS
    # beside a FAIL record is a disagreement that would otherwise be
    # hashed into the digest and sail through
    $qpRows = @(Get-Content $qpCorpusFile)
    if ($qpRows.Count -gt 0 -and $qpRows[-1] -ceq 'verdict=PASS') {
        throw '[CAP-7F] quickjs-package-corpus.txt ends in verdict=PASS while the harness records FAIL'
    }
    $quickjsPackageDigest = (Get-FileHash $qpCorpusFile -Algorithm SHA256).Hash.ToLowerInvariant()
} else {
    $quickjsPackageDigest = 'ABSENT'
}
Write-Host "[CAP-7F] quickjs_package_digest: $quickjsPackageDigest"
Write-Host "[CAP-7F] quickjs_package_corpus: $quickjsPackageCorpus (loadtime_bridge=$cap9b1LoadTimeBridge loader_wrong_thread=$cap9b1LoaderWrongThread store_wrong_thread=$cap9b1StoreWrongThread)"

# --- CAP-9B2 QuickJS lifecycle/reload corpus + one canonical digest ---------
# Identical honesty shape to the two blocks above: the harness is fully
# headless and never SKIPs, the counters are REQUIRED (an absent property
# throws rather than coercing to a fail-open 0), and the digest is the
# sha256 of build/cap9b2/quickjs-lifecycle-corpus.txt, which is identical
# on all four targets by construction - every fixture is generated
# in-process from byte constants, and every cross-thread ordering in the
# matrix is a rendezvous rather than a delay, so no line depends on how
# fast a particular runner happens to be.
$qlFile = Join-Path $repoRoot 'build/cap9b2/quickjslifecycle-windows-x86_64.json'
if (-not (Test-Path $qlFile)) {
    throw '[CAP-7F] quickjslifecycle-windows-x86_64.json missing -- the CAP-9B2 gate has not run in this workspace'
}
$ql = Get-Content $qlFile -Raw | ConvertFrom-Json
if ($ql.schema -ne 1) { throw '[CAP-7F] quickjslifecycle json schema mismatch' }
$quickjsLifecycleCorpus = "$($ql.overall)"
if ($quickjsLifecycleCorpus -notin @('PASS', 'FAIL')) {
    throw "[CAP-7F] quickjslifecycle json carries an unexpected verdict: $quickjsLifecycleCorpus"
}
# the six invariants the AGGREGATE re-refuses on its own, rather than
# trusting the harness's single verdict line
$cap9b2TwoActive = Read-MpCounter $ql 'two_active_generations'
$cap9b2Stale = Read-MpCounter $ql 'stale_completion'
$cap9b2ReloadLostOld = Read-MpCounter $ql 'reload_lost_old'
$cap9b2ExportWrongThread = Read-MpCounter $ql 'export_wrong_thread'
$cap9b2QuarantineUnexpected = Read-MpCounter $ql 'quarantine_unexpected'
# EXACTLY 1: the deliberately injected last-resort row. Zero would mean
# the quarantine path was never exercised at all, which is just as wrong
# as a spurious quarantine.
$cap9b2QuarantineInjected = Read-MpCounter $ql 'quarantine_injected'
$cap9b2DeniedBridge = Read-MpCounter $ql 'denied_bridge_add'
$cap9b2OpenerReached = Read-MpCounter $ql 'opener_reached'

$qlCorpusFile = Join-Path $repoRoot 'build/cap9b2/quickjs-lifecycle-corpus.txt'
if ($quickjsLifecycleCorpus -ceq 'PASS') {
    if (-not (Test-Path $qlCorpusFile)) {
        throw '[CAP-7F] quickjs-lifecycle-corpus.txt missing while the harness records PASS'
    }
    $qlRows = @(Get-Content $qlCorpusFile)
    if ($qlRows.Count -lt 2) {
        throw "[CAP-7F] quickjs-lifecycle-corpus.txt is empty or truncated ($($qlRows.Count) line(s))"
    }
    if ($qlRows[0] -cne 'schema=1') {
        throw '[CAP-7F] quickjs-lifecycle-corpus.txt carries no schema=1 header'
    }
    if ($qlRows[-1] -cne 'verdict=PASS') {
        throw '[CAP-7F] quickjs-lifecycle-corpus.txt does not end in verdict=PASS while the harness records PASS'
    }
    $quickjsLifecycleDigest = (Get-FileHash $qlCorpusFile -Algorithm SHA256).Hash.ToLowerInvariant()
} elseif (Test-Path $qlCorpusFile) {
    # the FAIL direction matters too: a corpus still carrying verdict=PASS
    # beside a FAIL record is a disagreement that would otherwise be
    # hashed into the digest and sail through
    $qlRows = @(Get-Content $qlCorpusFile)
    if ($qlRows.Count -gt 0 -and $qlRows[-1] -ceq 'verdict=PASS') {
        throw '[CAP-7F] quickjs-lifecycle-corpus.txt ends in verdict=PASS while the harness records FAIL'
    }
    $quickjsLifecycleDigest = (Get-FileHash $qlCorpusFile -Algorithm SHA256).Hash.ToLowerInvariant()
} else {
    $quickjsLifecycleDigest = 'ABSENT'
}
Write-Host "[CAP-7F] quickjs_lifecycle_digest: $quickjsLifecycleDigest"
Write-Host "[CAP-7F] quickjs_lifecycle_corpus: $quickjsLifecycleCorpus (two_active=$cap9b2TwoActive stale=$cap9b2Stale reload_lost_old=$cap9b2ReloadLostOld quarantine=$cap9b2QuarantineInjected/$cap9b2QuarantineUnexpected)"

# --- CAP-9C1 QuickJS release-package corpus + one canonical digest ----------
# Same honesty shape as the three blocks above, with ONE deliberate
# difference that is worth stating rather than hiding: the archive's
# SHA-256, its byte length and the generated registry's digest are
# recorded but are NOT four-way compared. CAP-6/CAP-7L already MEASURED
# that the mORMot static DEFLATE object emits different bytes for
# x86_64-win64 and x86_64-linux (pweb.test.bundle.pas pins app.pwb's
# golden hash per toolchain for exactly that reason), so requiring
# archive equality across targets would be requiring something untrue.
# What IS compared is the SEMANTIC corpus and the inventory digest -
# canonical names, uncompressed lengths and content digests - which are
# toolchain-independent and must be identical everywhere.
$qrFile = Join-Path $repoRoot 'build/cap9c1/quickjsrelease-windows-x86_64.json'
if (-not (Test-Path $qrFile)) {
    throw '[CAP-7F] quickjsrelease-windows-x86_64.json missing -- the CAP-9C1 gate has not run in this workspace'
}
$qr = Get-Content $qrFile -Raw | ConvertFrom-Json
if ($qr.schema -ne 1) { throw '[CAP-7F] quickjsrelease json schema mismatch' }
$quickjsReleaseCorpus = "$($qr.overall)"
if ($quickjsReleaseCorpus -notin @('PASS', 'FAIL')) {
    throw "[CAP-7F] quickjsrelease json carries an unexpected verdict: $quickjsReleaseCorpus"
}
# the five invariants the AGGREGATE re-refuses on its own
$cap9c1BrowserArrivals = Read-MpCounter $qr 'browser_store_arrivals'
$cap9c1DeniedBridge = Read-MpCounter $qr 'denied_bridge_add'
$cap9c1OpenerReached = Read-MpCounter $qr 'opener_reached'
$cap9c1TamperStarted = Read-MpCounter $qr 'tamper_started'
$cap9c1CwdDependency = Read-MpCounter $qr 'cwd_dependency'
# reported per target, never compared across them
$cap9c1PackageSha = "$($qr.package_sha256)"
$cap9c1PackageBytes = Read-MpCounter $qr 'package_bytes'
$cap9c1RegistrySha = "$($qr.registry_sha256)"
# compared across targets: this is the archive's MEANING, not its bytes
$cap9c1InventoryDigest = "$($qr.inventory_digest)"
if ($quickjsReleaseCorpus -ceq 'PASS' -and
    $cap9c1InventoryDigest -notmatch '^[0-9a-f]{64}$') {
    throw "[CAP-7F] quickjsrelease json carries a malformed inventory digest: $cap9c1InventoryDigest"
}
if ($quickjsReleaseCorpus -ceq 'PASS' -and
    $cap9c1PackageSha -notmatch '^[0-9a-f]{64}$') {
    throw "[CAP-7F] quickjsrelease json carries a malformed package digest: $cap9c1PackageSha"
}

$qrCorpusFile = Join-Path $repoRoot 'build/cap9c1/quickjs-release-corpus.txt'
if ($quickjsReleaseCorpus -ceq 'PASS') {
    if (-not (Test-Path $qrCorpusFile)) {
        throw '[CAP-7F] quickjs-release-corpus.txt missing while the harness records PASS'
    }
    $qrRows = @(Get-Content $qrCorpusFile)
    if ($qrRows.Count -lt 2) {
        throw "[CAP-7F] quickjs-release-corpus.txt is empty or truncated ($($qrRows.Count) line(s))"
    }
    if ($qrRows[0] -cne 'schema=1') {
        throw '[CAP-7F] quickjs-release-corpus.txt carries no schema=1 header'
    }
    if ($qrRows[-1] -cne 'verdict=PASS') {
        throw '[CAP-7F] quickjs-release-corpus.txt does not end in verdict=PASS while the harness records PASS'
    }
    # the staged release payload must exist beside the evidence: a green
    # corpus with no artifacts would be a gate that proved nothing shipped
    foreach ($staged in 'plugins.zip', 'pweb.quickjs.registry.inc',
                        'LICENSE.quickjs', 'package-inventory.txt',
                        'package-build-info.txt') {
        if (-not (Test-Path (Join-Path $repoRoot "build/quickjs-release/$staged"))) {
            throw "[CAP-7F] the CAP-9C1 release staging is missing $staged while the harness records PASS"
        }
    }
    $quickjsReleaseDigest = (Get-FileHash $qrCorpusFile -Algorithm SHA256).Hash.ToLowerInvariant()
} elseif (Test-Path $qrCorpusFile) {
    $qrRows = @(Get-Content $qrCorpusFile)
    if ($qrRows.Count -gt 0 -and $qrRows[-1] -ceq 'verdict=PASS') {
        throw '[CAP-7F] quickjs-release-corpus.txt ends in verdict=PASS while the harness records FAIL'
    }
    $quickjsReleaseDigest = (Get-FileHash $qrCorpusFile -Algorithm SHA256).Hash.ToLowerInvariant()
} else {
    $quickjsReleaseDigest = 'ABSENT'
}
Write-Host "[CAP-7F] quickjs_release_digest: $quickjsReleaseDigest"
Write-Host "[CAP-7F] quickjs_release_corpus: $quickjsReleaseCorpus (browser_store=$cap9c1BrowserArrivals denied_bridge=$cap9c1DeniedBridge tamper_started=$cap9c1TamperStarted cwd=$cap9c1CwdDependency)"
Write-Host "[CAP-7F] cap9c1 package sha256=$cap9c1PackageSha bytes=$cap9c1PackageBytes (per-target, reported not compared)"

# --- CAP-9C2 plugin-enabled GUI corpus + one canonical digest ---------------
# The shard's whole point is that the SAME architecture answers on all four
# targets, so unlike the C1 block above there is nothing here that is
# reported-but-not-compared: every field is a semantic verdict. The one
# per-machine fact - whether a file symlink could be created for the
# reparse-point negative - is carried as its own field so the aggregator
# can refuse a waiver instead of hashing one into the digest.
$qgFile = Join-Path $repoRoot 'build/cap9c2/quickjsgui-windows-x86_64.json'
if (-not (Test-Path $qgFile)) {
    throw '[CAP-7F] quickjsgui-windows-x86_64.json missing -- the CAP-9C2 gate has not run in this workspace'
}
$qg = Get-Content $qgFile -Raw | ConvertFrom-Json
if ($qg.schema -ne 1) { throw '[CAP-7F] quickjsgui json schema mismatch' }
$quickjsGuiCorpus = "$($qg.overall)"
if ($quickjsGuiCorpus -notin @('PASS', 'FAIL')) {
    throw "[CAP-7F] quickjsgui json carries an unexpected verdict: $quickjsGuiCorpus"
}
$cap9c2Listeners = Read-MpCounter $qg 'listeners'
$cap9c2Reparse = "$($qg.negative_reparse)"
$cap9c2License = "$($qg.license_quickjs_sha256)"

# The semantic gates, carried through individually so the aggregator can
# refuse a specific one by name instead of only noticing that a digest
# moved. The rule the aggregator applies is deliberately trivial - EVERY
# field here must read exactly 'yes' on EVERY target - because a gate
# whose expected value has to be looked up is a gate that gets a wrong
# expectation written next to it one day.
$cap9c2Gates = [ordered]@{}
foreach ($f in $CAP9C2_GATE_FIELDS) {
    $value = "$($qg.$f)"
    if ($quickjsGuiCorpus -ceq 'PASS' -and $value -eq '') {
        throw "[CAP-7F] quickjsgui record carries no '$f' gate -- refusing to default it"
    }
    $cap9c2Gates[$f] = $value
}

$qgCorpusFile = Join-Path $repoRoot 'build/cap9c2/quickjs-gui-corpus.txt'
if ($quickjsGuiCorpus -ceq 'PASS') {
    if (-not (Test-Path $qgCorpusFile)) {
        throw '[CAP-7F] quickjs-gui-corpus.txt missing while the gate records PASS'
    }
    $qgRows = @(Get-Content $qgCorpusFile)
    if ($qgRows.Count -lt 2) {
        throw "[CAP-7F] quickjs-gui-corpus.txt is empty or truncated ($($qgRows.Count) line(s))"
    }
    if ($qgRows[0] -cne 'schema=1') {
        throw '[CAP-7F] quickjs-gui-corpus.txt carries no schema=1 header'
    }
    if ($qgRows[-1] -cne 'verdict=PASS') {
        throw '[CAP-7F] quickjs-gui-corpus.txt does not end in verdict=PASS while the gate records PASS'
    }
    # a green corpus with no assembled release would be a gate that proved
    # nothing shipped
    foreach ($staged in 'quickjsapp.exe', 'app.pwb', 'plugins.zip',
                        'webview.dll', 'LICENSE.quickjs') {
        if (-not (Test-Path (Join-Path $repoRoot "build/cap9c2/release/$staged"))) {
            throw "[CAP-7F] the CAP-9C2 release layout is missing $staged while the gate records PASS"
        }
    }
    $quickjsGuiDigest = (Get-FileHash $qgCorpusFile -Algorithm SHA256).Hash.ToLowerInvariant()
} elseif (Test-Path $qgCorpusFile) {
    $qgRows = @(Get-Content $qgCorpusFile)
    if ($qgRows.Count -gt 0 -and $qgRows[-1] -ceq 'verdict=PASS') {
        throw '[CAP-7F] quickjs-gui-corpus.txt ends in verdict=PASS while the gate records FAIL'
    }
    $quickjsGuiDigest = (Get-FileHash $qgCorpusFile -Algorithm SHA256).Hash.ToLowerInvariant()
} else {
    $quickjsGuiDigest = 'ABSENT'
}
Write-Host "[CAP-7F] quickjs_gui_digest: $quickjsGuiDigest"
Write-Host "[CAP-7F] quickjs_gui_corpus: $quickjsGuiCorpus (listeners=$cap9c2Listeners reparse=$cap9c2Reparse)"

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
    capability_policy               = $capabilityPolicy
    capability_policy_digest        = $capabilityPolicyDigest
    navigation_security             = $navigationSecurity
    navigation_policy_digest        = $navigationPolicyDigest
    security_corpus                 = $securityCorpus
    security_corpus_digest          = $securityCorpusDigest
    cap8c_denied_soa                = $cap8cDeniedSoa
    cap8c_opener_nonmain            = $cap8cOpenerNonMain
    cap8c_secure_origin             = $cap8cSecureOrigin
    quickjs_corpus                  = $quickjsCorpus
    quickjs_corpus_digest           = $quickjsCorpusDigest
    cap9a_denied_bridge             = $cap9aDeniedBridge
    cap9a_opener_reached            = $cap9aOpenerReached
    quickjs_package_corpus          = $quickjsPackageCorpus
    quickjs_package_digest          = $quickjsPackageDigest
    cap9b1_loadtime_bridge          = $cap9b1LoadTimeBridge
    cap9b1_loader_wrong_thread      = $cap9b1LoaderWrongThread
    cap9b1_store_wrong_thread       = $cap9b1StoreWrongThread
    cap9b1_denied_bridge            = $cap9b1DeniedBridge
    cap9b1_source_open_after_failure = $cap9b1SourceOpen
    cap9b1_opener_reached           = $cap9b1OpenerReached
    quickjs_lifecycle_corpus        = $quickjsLifecycleCorpus
    quickjs_lifecycle_digest        = $quickjsLifecycleDigest
    cap9b2_two_active_generations   = $cap9b2TwoActive
    cap9b2_stale_completion         = $cap9b2Stale
    cap9b2_reload_lost_old          = $cap9b2ReloadLostOld
    cap9b2_export_wrong_thread      = $cap9b2ExportWrongThread
    cap9b2_quarantine_injected      = $cap9b2QuarantineInjected
    cap9b2_quarantine_unexpected    = $cap9b2QuarantineUnexpected
    cap9b2_denied_bridge            = $cap9b2DeniedBridge
    cap9b2_opener_reached           = $cap9b2OpenerReached
    quickjs_release_corpus          = $quickjsReleaseCorpus
    quickjs_release_digest          = $quickjsReleaseDigest
    cap9c1_inventory_digest         = $cap9c1InventoryDigest
    cap9c1_browser_store_arrivals   = $cap9c1BrowserArrivals
    cap9c1_denied_bridge            = $cap9c1DeniedBridge
    cap9c1_opener_reached           = $cap9c1OpenerReached
    cap9c1_tamper_started           = $cap9c1TamperStarted
    cap9c1_cwd_dependency           = $cap9c1CwdDependency
    cap9c1_package_sha256           = $cap9c1PackageSha
    cap9c1_package_bytes            = $cap9c1PackageBytes
    cap9c1_registry_sha256          = $cap9c1RegistrySha
    quickjs_gui_corpus              = $quickjsGuiCorpus
    quickjs_gui_digest              = $quickjsGuiDigest
    cap9c2_listeners                = $cap9c2Listeners
    cap9c2_negative_reparse         = $cap9c2Reparse
    cap9c2_license_sha256           = $cap9c2License
    cap9c2_gates                    = $cap9c2Gates
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
