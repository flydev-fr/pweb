# CAP-6 zero-network source sweep: the bundle unit, the bundler CLI,
# the release host and the bundle test suite may contain no HTTP/
# localhost/socket transport of any kind - the release path serves
# solely from app.pwb over the pweb://app custom scheme. The release
# host is additionally banned from every development fallback: no
# folder store, no fixture archive, no injected HTML, and no CWD
# lookup (the bundle lives beside the executable, never the CWD).
$ErrorActionPreference = 'Stop'

$cap6Files = @(
    'src/assets/pweb.assets.bundle.pas',
    'tools/bundler/pwebbundle.pas',
    'examples/08-release/releaseapp.pas',
    'test/assets/pweb.test.bundle.pas'
)
foreach ($f in $cap6Files) {
    if (-not (Test-Path $f)) { throw "swept file missing: $f" }
}

$forbidden = 'TRestHttpServer|THttpServer|mormot\.rest\.http|' +
    'mormot\.net\.(server|client|http)|localhost|127\.0\.0\.1|' +
    'socket|https?://|wss?://|file://'
$bad = 0
$hits = @(Select-String -Path $cap6Files -Pattern $forbidden -CaseSensitive:$false)
foreach ($h in $hits) {
    Write-Host "FORBIDDEN CAP-6 TRANSPORT PATTERN: $($h.Path):$($h.LineNumber): $($h.Line.Trim())"
    $bad++
}

# one asset-serving architecture in the release host - no fallback
$fallback = 'pweb\.assets\.folder|TFolderAssetStore|SetHtml|' +
    'webview_set_html|app\.zip|GetCurrentDir|SetCurrentDir'
$hits = @(Select-String -Path 'examples/08-release/releaseapp.pas' `
    -Pattern $fallback -CaseSensitive:$false)
foreach ($h in $hits) {
    Write-Host "FORBIDDEN RELEASE-HOST FALLBACK: $($h.Path):$($h.LineNumber): $($h.Line.Trim())"
    $bad++
}

if ($bad) { throw 'CAP-6 zero-network source proof failed' }
Write-Host 'CAP-6 zero-network source proof: PASS'
