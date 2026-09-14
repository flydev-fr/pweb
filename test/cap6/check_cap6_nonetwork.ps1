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
# CAP-15C EXTENDS IT BY EXACTLY ONE DOOR: `pweb.socketOpen | socketSend |
# socketReceive | socketClose`, behind the `network.socket` capability and
# the SAME compiled origin allowlist. The claim now reads:
#
#   no listening socket, no server, no second RPC path, and the only
#   outbound clients in the image are `pweb.rpc.fetch.mormot` and
#   `pweb.rpc.socket.mormot`, reachable only through `network.fetch` and
#   `network.socket` respectively.
#
# The file list below is unchanged and none of these files is a fetch unit,
# so the sweep is as strict about them as it ever was. The runtime half -
# this process owns no listening TCP socket - is untouched.
#
# CAP-15C ALSO NARROWS ONE WORD OF THE PATTERN, and says exactly how. The
# bundler now REFUSES a manifest carrying a `socket`, `sockets`,
# `websocket`, `ws` or `wss` field, so it has to spell those names - as
# string literals - to refuse them. A sweep that forbade the bare word would
# forbid the refusal, and spelling them `'sock' + 'et'` to get past it is
# exactly what the paragraph above refuses. So the word `socket` is matched
# in CODE - each line with its string literals and comments removed - which
# is where a transport would have to live (`uses sockets`, `TCrtSocket`,
# `fpSocket(`), while every URL and loopback pattern still reads the RAW
# line, literals included: a `ws://` endpoint is data, and data is what
# those patterns exist to find. The split is proven on planted vectors
# before a single file is swept, on every run.

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

# read on the RAW line: an endpoint, a loopback host or a server is DATA or
# a unit name, and either is refused wherever it is spelled
$forbiddenRaw = 'TRestHttpServer|THttpServer|mormot\.rest\.http|' +
    'mormot\.net\.(server|client|http)|localhost|127\.0\.0\.1|' +
    'https?://|wss?://|file://'
# read on CODE: a transport identifier
$forbiddenCode = 'socket'

# one Pascal line with its string literals emptied and its comments removed.
# A multi-line brace comment is NOT removed by a per-line pass, which errs
# toward refusing - the safe direction for a sweep
function CodeOf([string]$Line) {
    $s = [regex]::Replace($Line, "'(?:[^']|'')*'", "''")
    $s = [regex]::Replace($s, '\{[^}]*\}', ' ')
    $s = [regex]::Replace($s, '\(\*.*?\*\)', ' ')
    $i = $s.IndexOf('//')
    if ($i -ge 0) { $s = $s.Substring(0, $i) }
    return $s
}
function Offends([string]$Line) {
    return ($Line -match "(?i)$forbiddenRaw") -or
        ((CodeOf $Line) -match "(?i)$forbiddenCode")
}

# PROVEN TO FIRE, and proven not to refuse the refusal, before any file
$mustFire = @(
    'uses sockets;',
    '  sock := TCrtSocket.Create(5000);',
    '  fd := fpSocket(AF_INET, SOCK_STREAM, 0);',
    "  url := 'ws://127.0.0.1:5173/';",
    "  endpoint := 'wss://evil.example/feed';",
    "  host := 'localhost';",
    '  s := TSocket(0); // the comment is not what fires',
    '  mormot.net.client,'
)
$mustPass = @(
    "      if (name = 'network') or (name = 'origins') or",
    "         (name = 'socket') or (name = 'sockets') or",
    "         (name = 'websocket') or (name = 'ws') or (name = 'wss') then",
    "      // CAP-15C: the socket door's names join the refusal - a bundle can",
    '  { a manifest field named socket is refused below }'
)
foreach ($v in $mustFire) {
    if (-not (Offends $v)) { throw "the CAP-6 pattern no longer fires on a planted transport: $v" }
}
foreach ($v in $mustPass) {
    if (Offends $v) { throw "the CAP-6 pattern refuses a refusal it must allow: $v" }
}
Write-Host ("CAP-6 pattern self-test: fires on $($mustFire.Count) planted transports, " +
    "passes $($mustPass.Count) refusal lines")

$bad = 0
foreach ($f in $cap6Files) {
    $full = (Resolve-Path $f).Path
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($full)) {
        $lineNo++
        if (Offends $line) {
            Write-Host "FORBIDDEN CAP-6 TRANSPORT PATTERN: ${full}:${lineNo}: $($line.Trim())"
            $bad++
        }
    }
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
