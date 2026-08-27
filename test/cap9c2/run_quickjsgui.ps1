# CAP-9C2: the plugin-enabled release layout and its real-GUI acceptance,
# on Windows x64.
#
# Order matters and is the point:
#
#   1. reuse the CAP-9C1 release payload staged earlier in this job
#      (plugins.zip + the generated registry + LICENSE.quickjs). C2 does
#      not re-derive the package: the whole shard rests on C1's frozen
#      builder, and building it twice would prove a second builder;
#   2. build app.pwb from the plugin-enabled acceptance frontend;
#   3. compile the host WITH the generated registry include (-Fi), so
#      "the registry is compiled into the executable" is a fact of the
#      gate rather than a claim;
#   4. assemble the EXACT release layout and assert it entry by entry -
#      files, directories and symlinks/reparse points;
#   5. run it from an unrelated working directory, sampling listening
#      sockets while the UI and the plugins are both live;
#   6. run the whole-archive NEGATIVE matrix against that same real
#      layout: missing, truncated, over-long, wrong digest, wrong
#      inventory, registry mismatch, reparse-point. Every one must exit
#      nonzero having created no WebView and reached no service;
#   7. run the hostile-package real-GUI harness (running=1, failed=1);
#   8. assemble ONE corpus from the host rows, the hostile rows and the
#      rows this runner measures itself, and hash it.
#
# The host drives the real mORMot SOA bridge, so it compiles INSIDE the
# CAP-3U window (apply -> compile -> restore + verify pristine), exactly
# like the CAP-6 release host and the CAP-8B/8C/9C1 harnesses.
#
# NO conditional SKIP: CAP-8B/8C already prove a real WebView opens on
# the hosted Windows runner, so a failure here gates.
#
# Writes: build/cap9c2/quickjsgui-windows-x86_64.json (PASS|FAIL),
#         build/cap9c2/quickjs-gui-corpus.txt (the digest source),
#         build/cap9c2/release/ (the real plugin-enabled layout) + logs.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot
New-Item -ItemType Directory -Force build/cap9c2 | Out-Null
$work = (Resolve-Path build/cap9c2).Path
$json = Join-Path $work 'quickjsgui-windows-x86_64.json'
$corpus = Join-Path $work 'quickjs-gui-corpus.txt'
$hostRows = Join-Path $work 'host-rows.txt'
$hostileRows = Join-Path $work 'hostile-rows.txt'
$runnerRows = Join-Path $work 'runner-rows.txt'
$log = Join-Path $work 'quickjsgui-win.log'
# every output deleted up front: an aborted run must never leave a
# previous run's evidence where the emitter or an upload could find it
Remove-Item -Force -ErrorAction SilentlyContinue $json, $corpus, $hostRows,
    $hostileRows, $runnerRows, $log

$payload = Join-Path $repoRoot 'build\quickjs-release'
foreach ($pre in 'examples/07-quickjs/quickjsapp.pas',
                 'examples/07-quickjs/frontend/dist/index.html',
                 'examples/07-quickjs/frontend/dist/assets/app.js',
                 'test/cap9c2/quickjsgui.pas',
                 'test/cap9c2/fixture/index.html',
                 'test/cap9c2/fixture/assets/driver.js',
                 'build/webview-dist/webview.dll',
                 'build/webview-dist/LICENSE.webview',
                 'build/webview-dist/LICENSE.webview2sdk',
                 'build/quickjs-release/plugins.zip',
                 'build/quickjs-release/pweb.quickjs.registry.inc',
                 'build/quickjs-release/LICENSE.quickjs',
                 'tools/bundler/pwebbundle.pas',
                 'tools/patch-cap3u.ps1') {
    if (-not (Test-Path $pre)) {
        throw ("missing precondition: $pre -- the CAP-4W/CAP-9C1 gates and the " +
            'CAP-9C2 frontend build must have run in this workspace first')
    }
}

$rows = New-Object System.Collections.Generic.List[string]
function Add-Row([string]$Name, [bool]$Ok, [string]$Detail) {
    $value = if ($Ok) { 'yes' } else { 'no' }
    $rows.Add("$Name=$value")
    if ($Detail) { Write-Host "[CAP-9C2] $Name=$value | $Detail" }
    else { Write-Host "[CAP-9C2] $Name=$value" }
    if (-not $Ok) {
        # The failing process's own output goes to the JOB log, not only to
        # a file an upload step may never reach: a hosted gate that fails
        # while its diagnostics live in a skipped artifact costs a whole
        # 20-minute cycle to learn nothing. MEASURED on run 33017918894.
        if (Test-Path $log) {
            Write-Host '----- CAP-9C2 process output (tail) -----'
            Get-Content $log -Tail 120 | ForEach-Object { Write-Host $_ }
            Write-Host '----- end of process output -----'
        }
        throw "CAP-9C2 gate failed: $Name ($Detail)"
    }
}

# the canonical marker, from the one source
$passConst = @(Select-String -Path test/cap9c2/quickjsgui.pas `
    -Pattern "^  MARKER_PASS = '([^']+)';$" -CaseSensitive)
if ($passConst.Count -ne 1) {
    throw "expected one MARKER_PASS constant in quickjsgui.pas, found $($passConst.Count)"
}
$hostilePass = $passConst[0].Matches[0].Groups[1].Value
$verdictConst = @(Select-String -Path examples/07-quickjs/quickjsapp.pas `
    -Pattern "^    ': (.+) PASS';$" -CaseSensitive)
if ($verdictConst.Count -ne 1) {
    throw "expected one VERDICT_PASS constant in quickjsapp.pas, found $($verdictConst.Count)"
}
$hostPass = 'quickjsapp: ' + $verdictConst[0].Matches[0].Groups[1].Value + ' PASS'
Write-Host "[CAP-9C2] canonical host marker: $hostPass"
Write-Host "[CAP-9C2] canonical hostile marker: $hostilePass"

$mormotUnits = @(
    '-Fideps/mormot2/src', '-Fudeps/mormot2/src/core', '-Fudeps/mormot2/src/lib',
    '-Fudeps/mormot2/src/crypt', '-Fudeps/mormot2/src/net', '-Fudeps/mormot2/src/db',
    '-Fudeps/mormot2/src/orm', '-Fudeps/mormot2/src/rest', '-Fudeps/mormot2/src/soa',
    '-Fudeps/mormot2/src/script'
)
$hostUnits = @('-Fusrc/lib', '-Fusrc/rpc', '-Fusrc/security', '-Fusrc/webview',
    '-Fusrc/assets', '-Fusrc/script', '-Fusrc/platform/windows')

# --- 0. app.pwb carries NO plugin source, and plugins.zip NO frontend ------
# The two archives are independent security domains, so the claim is
# checked on the artifacts rather than deduced from the code that built
# them. Anything under a plugin root, or any plugin manifest/entry name,
# appearing in app.pwb is a domain leak; and the reverse for plugins.zip.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Get-ZipNames([string]$Path) {
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $Path).Path)
    try { return @($zip.Entries | ForEach-Object FullName) } finally { $zip.Dispose() }
}

# --- 1. build the bundler and app.pwb --------------------------------------
New-Item -ItemType Directory -Force build/cap9c2/bundler-fpc, build/cap9c2/bin,
    build/cap9c2/app-fpc, build/cap9c2/app-bin, build/cap9c2/gui-fpc,
    build/cap9c2/gui-bin | Out-Null
fpc -Px86_64 -Twin64 -MObjFPC -Sh -B -FUbuild/cap9c2/bundler-fpc -FEbuild/cap9c2/bin `
    -Fusrc/assets -Fusrc/rpc @mormotUnits `
    -Fldeps/mormot2/static/x86_64-win64 tools/bundler/pwebbundle.pas
if ($LASTEXITCODE -ne 0) { throw 'CAP-9C2 bundler compile FAILED' }

$release = Join-Path $work 'release'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $release
New-Item -ItemType Directory -Force $release | Out-Null
& build/cap9c2/bin/pwebbundle.exe examples/07-quickjs/frontend/dist `
    (Join-Path $release 'app.pwb')
if ($LASTEXITCODE -ne 0) { throw 'CAP-9C2 app.pwb build FAILED' }

$appNames = Get-ZipNames (Join-Path $release 'app.pwb')
$pluginNames = Get-ZipNames (Join-Path $payload 'plugins.zip')
$leak = @($appNames | Where-Object {
    $_ -match '^quickjs\.' -or $_ -match 'plugin\.json$' -or $_ -match '(^|/)main\.js$'
})
Add-Row 'app_pwb_carries_no_plugin_source' ($leak.Count -eq 0) "entries=$($appNames.Count) leak=$($leak -join ',')"
$leak = @($pluginNames | Where-Object {
    $_ -match 'index\.html$' -or $_ -match '^assets/' -or $_ -match 'manifest\.json$'
})
Add-Row 'plugins_zip_carries_no_frontend' ($leak.Count -eq 0) "entries=$($pluginNames.Count) leak=$($leak -join ',')"

# --- 0b. no CWD dependence, no discovery: source facts ---------------------
# Two of this shard's Never-list items are properties of ALL inputs, not of
# the inputs a test happened to choose, and a source sweep is the only
# place they can be proven that way. The host may read argv and the
# environment - that is how a headless gate drives it, exactly as the CAP-6
# release host does - but it must never resolve a path against the working
# directory, and neither program may scan, watch or enumerate a directory.
$cwdRx = 'GetCurrentDir|SetCurrentDir|ChDir'
$discoveryRx = 'FindFirst|FindNext|FileAge|ReadDirectory|FindFirstChangeNotification|inotify|FSEvent|kqueue'
$hits = @(Select-String -Path 'examples/07-quickjs/quickjsapp.pas' -Pattern $cwdRx)
Add-Row 'host_no_cwd_resolution' ($hits.Count -eq 0) "hits=$($hits.Count)"
$anchor = @(Select-String -Path 'examples/07-quickjs/quickjsapp.pas' `
    -Pattern 'Executable\.ProgramFilePath')
Add-Row 'host_resolves_from_executable' ($anchor.Count -ge 2) "sites=$($anchor.Count)"
$hits = @(Select-String -Path 'examples/07-quickjs/quickjsapp.pas',
    'test/cap9c2/quickjsgui.pas' -Pattern $discoveryRx)
Add-Row 'no_plugin_discovery_or_watching' ($hits.Count -eq 0) "hits=$($hits.Count)"

# --- 2. compile the host WITH the generated registry, inside CAP-3U --------
try {
    pwsh -NoProfile -File tools/patch-cap3u.ps1
    if ($LASTEXITCODE -ne 0) { throw 'CAP-9C2 CAP-3U re-apply failed' }
    fpc -Px86_64 -Twin64 -MObjFPC -Sh -B -Xm `
        -FUbuild/cap9c2/app-fpc -FEbuild/cap9c2/app-bin `
        @hostUnits -Fibuild/quickjs-release @mormotUnits `
        -Fldeps/mormot2/static/x86_64-win64 examples/07-quickjs/quickjsapp.pas
    if ($LASTEXITCODE -ne 0) { throw 'quickjsapp.pas compile FAILED' }
    fpc -Px86_64 -Twin64 -MObjFPC -Sh -B -Xm `
        -FUbuild/cap9c2/gui-fpc -FEbuild/cap9c2/gui-bin `
        @hostUnits @mormotUnits `
        -Fldeps/mormot2/static/x86_64-win64 test/cap9c2/quickjsgui.pas
    if ($LASTEXITCODE -ne 0) { throw 'quickjsgui.pas compile FAILED' }
}
finally {
    $restoreFailures = @()
    foreach ($attempt in 1..2) {
        pwsh -NoProfile -File tools/patch-cap3u.ps1 -Restore
        if ($LASTEXITCODE -ne 0) { $restoreFailures += $attempt }
    }
    if ($restoreFailures) {
        throw "CAP-9C2 CAP-3U restore attempts failed: $($restoreFailures -join ', ')"
    }
}
git -C deps/mormot2 diff --exit-code HEAD -- src/core/mormot.core.interfaces.pas
if ($LASTEXITCODE -ne 0) { throw 'CAP-3U source is not pristine after CAP-9C2 restore' }
Add-Row 'registry_compiled_into_host' (Test-Path build/cap9c2/app-bin/quickjsapp.exe) ''

# --- 3. assemble the EXACT release layout ----------------------------------
Copy-Item -Force build/cap9c2/app-bin/quickjsapp.exe $release
Copy-Item -Force (Join-Path $payload 'plugins.zip') $release
Copy-Item -Force (Join-Path $payload 'LICENSE.quickjs') $release
Copy-Item -Force build/webview-dist/webview.dll $release
Copy-Item -Force build/webview-dist/LICENSE.webview $release
Copy-Item -Force build/webview-dist/LICENSE.webview2sdk $release

# files, directories AND reparse points, enumerated - "smallest possible"
# is a claim that rots silently unless the whole set is asserted
function Get-LayoutListing([string]$Root) {
    $items = @(Get-ChildItem -LiteralPath $Root -Recurse -Force |
        ForEach-Object {
            $rel = $_.FullName.Substring($Root.Length).TrimStart('\')
            $kind = if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { 'link' }
                    elseif ($_.PSIsContainer) { 'dir' } else { 'file' }
            "$kind`:$($rel -replace '\\', '/')"
        })
    return @($items | Sort-Object -CaseSensitive)
}
$expectedLayout = @(
    'file:LICENSE.quickjs', 'file:LICENSE.webview', 'file:LICENSE.webview2sdk',
    'file:app.pwb', 'file:plugins.zip', 'file:quickjsapp.exe', 'file:webview.dll'
) | Sort-Object -CaseSensitive
$actualLayout = Get-LayoutListing $release
Add-Row 'release_layout_exact' `
    (($actualLayout -join '|') -ceq ($expectedLayout -join '|')) `
    "got=[$($actualLayout -join ' ')]"

# the generated registry is compiled IN and never shipped
Add-Row 'registry_not_shipped' `
    (-not (Test-Path (Join-Path $release 'pweb.quickjs.registry.inc'))) ''

# the frozen QuickJS licence, hash-pinned, present exactly once
$licenseSha = (Get-FileHash (Join-Path $release 'LICENSE.quickjs') -Algorithm SHA256).Hash.ToLowerInvariant()
Add-Row 'license_quickjs_sha256' `
    ($licenseSha -ceq '8310e7a6c52cd3b45a0aedb5620ef79408c8c155594f37259ba801f6a2fbe2fc') `
    "sha256=$licenseSha"
$licenseCount = @($actualLayout | Where-Object { $_ -eq 'file:LICENSE.quickjs' }).Count
Add-Row 'license_quickjs_once' ($licenseCount -eq 1) "count=$licenseCount"
# and it is NOT inside either archive
Add-Row 'license_not_embedded' `
    ((@($appNames | Where-Object { $_ -match 'LICENSE' }).Count -eq 0) -and
     (@($pluginNames | Where-Object { $_ -match 'LICENSE' }).Count -eq 0)) ''

$exe = (Join-Path $release 'quickjsapp.exe')
$goldenArchive = Join-Path $work 'plugins.zip.golden'
Copy-Item -Force (Join-Path $release 'plugins.zip') $goldenArchive

# --- 4. run the host from an unrelated CWD, sampling listeners -------------
function Invoke-Host([string]$Tag, [string[]]$HostArgs, [switch]$SampleListeners) {
    $outFile = Join-Path $work "run-$Tag.out"
    $errFile = Join-Path $work "run-$Tag.err"
    Remove-Item -Force -ErrorAction SilentlyContinue $outFile, $errFile
    $proc = Start-Process -FilePath $exe -ArgumentList $HostArgs `
        -WorkingDirectory ([System.IO.Path]::GetTempPath()) `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -NoNewWindow -PassThru
    $listeners = 0
    if ($SampleListeners) {
        # sampled WHILE the UI and the plugins are both live, never after:
        # a socket opened and closed between runs would be invisible
        for ($i = 0; $i -lt 60 -and -not $proc.HasExited; $i++) {
            try {
                $n = @(Get-NetTCPConnection -State Listen -OwningProcess $proc.Id `
                        -ErrorAction SilentlyContinue).Count
                $u = @(Get-NetUDPEndpoint -OwningProcess $proc.Id `
                        -ErrorAction SilentlyContinue).Count
                if (($n + $u) -gt $listeners) { $listeners = $n + $u }
            } catch { }
            Start-Sleep -Milliseconds 500
        }
    }
    $proc.WaitForExit()
    $text = ''
    foreach ($f in @($outFile, $errFile)) {
        if (Test-Path $f) { $text += (Get-Content $f -Raw) }
    }
    Add-Content -Path $log -Value "===== $Tag (exit $($proc.ExitCode)) ====="
    Add-Content -Path $log -Value $text
    return [pscustomobject]@{
        Exit = $proc.ExitCode; Text = $text; Listeners = $listeners
    }
}

$verdictFile = Join-Path $work 'host-verdict.txt'
$r = Invoke-Host 'green' @("--pweb-verdict=$verdictFile",
    "--pweb-corpus=$hostRows", '--pweb-autoclose-ms=240000') -SampleListeners
Add-Row 'host_exit_zero' ($r.Exit -eq 0) "exit=$($r.Exit)"
Add-Row 'host_pass_marker' ($r.Text -cmatch [regex]::Escape($hostPass)) ''
Add-Row 'host_corpus_written' (Test-Path $hostRows) ''
# captured NOW, into its own variable: $r is reused by the negative
# matrix below, and a listener count read after that would be the count
# of a different process
$listenerMax = $r.Listeners
Add-Row 'listeners' ($listenerMax -eq 0) "max_sampled=$listenerMax"
$rows.Add("listeners_count=$listenerMax")

# --- 5. the whole-archive NEGATIVE matrix, on the REAL layout --------------
# Each row replaces plugins.zip in the assembled release and requires a
# controlled nonzero exit with the typed refusal marker, no WebView and
# no service reached. The host prints its pre-WebView counters on that
# path, so "no WebView was created" is read from the process, not assumed.
$archive = Join-Path $release 'plugins.zip'
$goldenBytes = [System.IO.File]::ReadAllBytes($goldenArchive)

function Test-Refusal([string]$Tag, [string]$ExpectCode) {
    $r = Invoke-Host $Tag @('--pweb-autoclose-ms=60000')
    $ok = ($r.Exit -ne 0) -and
          ($r.Text -match 'plugins\.zip REFUSED \(' + [regex]::Escape($ExpectCode) + '\)') -and
          ($r.Text -match 'webviews_created=0') -and
          ($r.Text -match 'soa_calls=0') -and
          ($r.Text -notmatch [regex]::Escape($hostPass))
    Add-Row "negative_$Tag" $ok "exit=$($r.Exit) expect=$ExpectCode"
}

Remove-Item -Force $archive
Test-Refusal 'missing' 'package_missing'

$half = New-Object byte[] ([int]($goldenBytes.Length / 2))
[Array]::Copy($goldenBytes, $half, $half.Length)
[System.IO.File]::WriteAllBytes($archive, $half)
Test-Refusal 'truncated' 'package_size'

$long = New-Object byte[] ($goldenBytes.Length + 64)
[Array]::Copy($goldenBytes, $long, $goldenBytes.Length)
[System.IO.File]::WriteAllBytes($archive, $long)
Test-Refusal 'overlong' 'package_size'

# same LENGTH, different bytes: only the digest can refuse this one
$flipped = $goldenBytes.Clone()
$flipped[[int]($flipped.Length / 2)] = $flipped[[int]($flipped.Length / 2)] -bxor 0xFF
[System.IO.File]::WriteAllBytes($archive, $flipped)
Test-Refusal 'digest' 'package_digest'

# a reparse point where a regular file must be: the verifier opens ONE
# handle refusing indirection, so this is refused before a byte is read
Remove-Item -Force $archive
$reparseResult = 'waived'
$linkOk = $false
try {
    New-Item -ItemType SymbolicLink -Path $archive -Target $goldenArchive -ErrorAction Stop | Out-Null
    $linkOk = $true
} catch {
    # creating a file symlink needs SeCreateSymbolicLinkPrivilege, which a
    # non-elevated dev shell does not have. The hosted runner does.
    Write-Host '[CAP-9C2] symlink creation unavailable (no privilege)'
}
if ($linkOk) {
    # deliberately OUTSIDE the corpus rows: this one leg's availability is
    # a property of the machine, and a corpus row that reads 'yes' on the
    # runner and 'waived' on a dev host would break the four-way digest
    # for a reason that has nothing to do with the product. It goes into
    # the JSON instead, where the aggregator REFUSES anything but 'yes' -
    # the same "never promote a waiver" discipline the CAP-7F matrix uses.
    $r2 = Invoke-Host 'reparse' @('--pweb-autoclose-ms=60000')
    $ok = ($r2.Exit -ne 0) -and
          ($r2.Text -match 'plugins\.zip REFUSED \(package_unreadable\)') -and
          ($r2.Text -match 'webviews_created=0') -and
          ($r2.Text -match 'soa_calls=0')
    if (-not $ok) {
        throw "CAP-9C2 gate failed: negative_reparse (exit=$($r2.Exit))"
    }
    $reparseResult = 'yes'
}
Write-Host "[CAP-9C2] negative_reparse=$reparseResult (json only, never in the digest)"

# WHAT THIS MATRIX CANNOT REACH, stated rather than quietly omitted.
# Two ratified refusal rows - a structurally invalid archive whose
# whole-archive digest MATCHES its bytes, and an archive whose semantic
# inventory or registry disagrees with a digest that is otherwise
# correct - cannot be produced from outside a compiled host: they need
# the registry to be a PARAMETER so the expectation can be mutated
# instead of the bytes. That is precisely how CAP-9C1 proves them
# (archive_invalid, inventory_mismatch, inventory_count, registry), on a
# mutated registry copy, in the SAME job that runs this gate. Recorded
# here so a reader of this matrix is not left to infer coverage it does
# not have.
$rows.Add('negative_inventory_and_registry=cap9c1')

# restore the good archive and prove the layout is green again - a
# negative matrix that left the layout broken would make every later row
# vacuous.
#
# The Remove-Item is load-bearing, not tidiness: after the reparse leg
# $archive is a SYMLINK whose target IS $goldenArchive, so copying the
# golden file over it resolves to copying a file onto itself and
# PowerShell refuses with 'Cannot overwrite the item ... with itself'.
# The POSIX sibling deletes first for the same reason.
Remove-Item -Force -ErrorAction SilentlyContinue $archive
Copy-Item -Force $goldenArchive $archive
$r = Invoke-Host 'restored' @("--pweb-corpus=$hostRows",
    '--pweb-autoclose-ms=240000')
Add-Row 'layout_recovers_after_negatives' `
    (($r.Exit -eq 0) -and ($r.Text -cmatch [regex]::Escape($hostPass))) `
    "exit=$($r.Exit)"

# --- 6. the hostile-package real-GUI harness -------------------------------
Copy-Item -Force build/webview-dist/webview.dll build/cap9c2/gui-bin/
$guiExe = (Resolve-Path build/cap9c2/gui-bin/quickjsgui.exe).Path
$guiOut = Join-Path $work 'run-hostile.out'
$guiErr = Join-Path $work 'run-hostile.err'
Remove-Item -Force -ErrorAction SilentlyContinue $guiOut, $guiErr
$proc = Start-Process -FilePath $guiExe `
    -ArgumentList @("--pweb-corpus=$hostileRows", '--pweb-autoclose-ms=240000') `
    -WorkingDirectory ([System.IO.Path]::GetTempPath()) `
    -RedirectStandardOutput $guiOut -RedirectStandardError $guiErr `
    -NoNewWindow -PassThru
$proc.WaitForExit()
$guiText = ''
foreach ($f in @($guiOut, $guiErr)) {
    if (Test-Path $f) { $guiText += (Get-Content $f -Raw) }
}
Add-Content -Path $log -Value '===== hostile ====='
Add-Content -Path $log -Value $guiText
Add-Row 'hostile_exit_zero' ($proc.ExitCode -eq 0) "exit=$($proc.ExitCode)"
Add-Row 'hostile_pass_marker' ($guiText -cmatch [regex]::Escape($hostilePass)) ''
Add-Row 'hostile_corpus_written' (Test-Path $hostileRows) ''

# --- 7. assemble ONE corpus and hash it ------------------------------------
[System.IO.File]::WriteAllText($runnerRows,
    (($rows -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
$all = New-Object System.Collections.Generic.List[string]
$all.Add('schema=1')
foreach ($file in @($hostRows, $hostileRows, $runnerRows)) {
    foreach ($line in (Get-Content $file)) {
        if ($line.Trim()) { $all.Add($line.TrimEnd()) }
    }
}
$all.Add('verdict=PASS')
[System.IO.File]::WriteAllText($corpus,
    (($all -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
$digest = (Get-FileHash $corpus -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "[CAP-9C2] quickjs_gui_digest: $digest"

function Row-Value([string]$Name) {
    $hit = @($all | Where-Object { $_ -like "$Name=*" })
    if ($hit.Count -eq 0) { return '' }
    return ($hit[0] -replace "^$([regex]::Escape($Name))=", '')
}
$verdict = [ordered]@{
    schema                        = 1
    target                        = 'windows-x86_64'
    overall                       = 'PASS'
    gui_digest                    = $digest
    listeners                     = $listenerMax
    negative_reparse              = $reparseResult
    ui_add                        = (Row-Value 'ui_add')
    quickjs_add                   = (Row-Value 'quickjs_add')
    reporting_code                = (Row-Value 'reporting_code')
    reporting_status              = (Row-Value 'reporting_status')
    reporting_soa_count           = (Row-Value 'reporting_soa_count')
    reporting_denied_bridge       = (Row-Value 'reporting_denied_bridge_delta')
    opener_reached                = (Row-Value 'opener_reached')
    ui_rendered                   = (Row-Value 'ui_rendered')
    concurrent_overlap            = (Row-Value 'concurrent_overlap')
    no_cross_delivery             = (Row-Value 'no_cross_delivery')
    plugin_archive_verified       = (Row-Value 'plugin_archive_verified')
    plugin_inventory_verified     = (Row-Value 'plugin_inventory_verified')
    quickjs_window_absent         = (Row-Value 'quickjs_window_absent')
    quickjs_document_absent       = (Row-Value 'quickjs_document_absent')
    quickjs_webkit_channel_absent = (Row-Value 'quickjs_webkit_channel_absent')
    quickjs_webview2_channel_absent = (Row-Value 'quickjs_webview2_channel_absent')
    quickjs_raw_webview_invoke_absent = (Row-Value 'quickjs_raw_webview_invoke_absent')
    same_scheduler                = (Row-Value 'same_scheduler')
    same_policy                   = (Row-Value 'same_policy')
    same_bridge                   = (Row-Value 'same_bridge')
    same_server                   = (Row-Value 'same_server')
    browser_plugin_store_arrivals = (Row-Value 'browser_plugin_store_arrivals')
    quickjs_app_store_arrivals    = (Row-Value 'quickjs_app_store_arrivals')
    browser_plugin_script_marker  = (Row-Value 'browser_plugin_script_marker')
    raw_channel_source_bytes      = (Row-Value 'raw_channel_source_bytes')
    neighbour_survived_timeout    = (Row-Value 'neighbour_survived_timeout')
    ui_survived_timeout           = (Row-Value 'ui_survived_timeout')
    reload_generation_changed     = (Row-Value 'reload_generation_changed')
    clean_shutdown                = (Row-Value 'clean_shutdown')
    hostile_running               = (Row-Value 'h1_running_plugins')
    hostile_failed                = (Row-Value 'h1_failed_plugins')
    license_quickjs_sha256        = $licenseSha
    release_layout                = (Row-Value 'release_layout_exact')
}
[System.IO.File]::WriteAllText($json,
    ($verdict | ConvertTo-Json -Depth 4) + "`n",
    [System.Text.UTF8Encoding]::new($false))

Write-Host '[CAP-9C2] quickjsgui verdict: PASS'
