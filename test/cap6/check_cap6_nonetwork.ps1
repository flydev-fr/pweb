# CAP-6 zero-network source sweep: the bundle unit, the bundler CLI,
# the release host and the bundle test suite may contain no HTTP/
# localhost/socket transport of any kind - the release path serves
# solely from app.pwb over the pweb://app custom scheme. The release
# host is additionally banned from every development fallback: no
# folder store, no fixture archive, no injected HTML, and no CWD
# lookup (the bundle lives beside the executable, never the CWD).
#
# CAP-14A joins the CSP policy unit to the swept set: it decides what a
# bundle may carry and has no more business naming a transport than the
# writer beside it does.
#
# `test/assets/pweb.test.htmlpolicy.pas` is DELIBERATELY NOT SWEPT, and
# the exclusion is the point rather than an omission: that suite's whole
# job is to prove a cross-origin `https://` script src is refused, so it
# has to spell one. A sweep that forbade the fixture would forbid the
# proof, and a fixture spelled `'htt' + 'ps://'` to dodge a gate is a
# gate that has stopped meaning anything. The unit under test is swept;
# the corpus that attacks it is not.
#
# CAP-15B RE-SCOPES THIS CLAIM, and does not delete it. A native outbound
# door now exists - `pweb.fetch`, behind the `network.fetch` capability and
# an origin allowlist compiled into each application - so "no HTTP client
# anywhere" stopped being true as written. What is asserted from CAP-15B
# onward is the half that was always load-bearing, stated exactly:
#
#   no listening socket, no server, no second RPC path, and the only
#   outbound client in the image is `pweb.rpc.fetch.mormot`, reachable only
#   through `network.fetch`.
#
# The file list below is unchanged and none of these files is a fetch unit,
# so the sweep is as strict about them as it ever was. The runtime half -
# this process owns no listening TCP socket - is untouched.

$ErrorActionPreference = 'Stop'

$cap6Files = @(
    'src/assets/pweb.assets.bundle.pas',
    'src/assets/pweb.assets.htmlpolicy.pas',
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
