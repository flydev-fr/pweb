# CAP-5 zero-network source sweep: neither SDK nor either acceptance
# frontend may contain an HTTP/socket/loopback transport or any browser
# network entry point for RPC. The SDKs are held to the strictest bar -
# no fetch/XHR/WebSocket at all. Frontend sources are additionally
# forbidden from addressing the raw native primitive (__pweb_invoke):
# the acceptance apps must go through the SDKs and nothing else.
# Directories are globbed recursively so a newly added source file can
# never silently escape the sweep. Committed sources are swept; the
# bundled React framework internals are third-party browser code and
# PWeb RPC never travels through them.
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

$sdkFiles = @(
    Get-ChildItem sdk/typescript/src -Recurse -File | ForEach-Object FullName
    Get-ChildItem sdk/typescript/test -Recurse -File | ForEach-Object FullName
    Get-ChildItem sdk/pas2js -Recurse -File -Filter *.pas | ForEach-Object FullName
)
$frontendFiles = @(
    Get-ChildItem examples/04-react/frontend/src -Recurse -File | ForEach-Object FullName
    Get-ChildItem examples/05-pas2js/frontend/src -Recurse -File | ForEach-Object FullName
    'examples/04-react/frontend/build.mjs',
    'examples/05-pas2js/frontend/build.ps1'
)
# `fetch(` means the BROWSER's fetch, so the match is anchored on a
# non-identifier byte before it. Without that, CAP-15B's `httpFetch(` and
# `PWebFetch(` - each of which is ONE `invoke` of the runtime-owned
# `pweb.fetch` and opens nothing - would be refused for the way they are
# spelled. `window.fetch(` and `globalThis.fetch(` are still caught, because
# a dot is not an identifier byte.
$network = '(?<![A-Za-z0-9_])fetch\s*\(|XMLHttpRequest|WebSocket|EventSource|' +
    'sendBeacon|localhost|127\.0\.0\.1|http://|https://|file://|' +
    'TRestHttpServer|THttpServer|mormot\.net\.(server|client|http)'

# CAP-8B carve-out, FRONTENDS ONLY (the SDK bar stays absolute): the
# navigation-security verdict needs probe vectors whose whole point is to
# be blocked. A hit line is permitted iff it carries the explicit
# `cap8b-navsec-probe` marker AND either (a) every http(s) URL on it
# addresses the RFC 2606/6761 reserved `.invalid` TLD - unresolvable by
# construction, so even a total enforcement regression reaches nothing -
# or (b) it carries no URL at all and is a fetch of a pweb-origin probe
# constant (the `connect-src 'self'` control pair). Socket/loopback/file
# primitives are NEVER permitted, marker or not, and the per-file marker
# counts are PINNED so the carve-out cannot grow silently.
$marker = 'cap8b-navsec-probe'
$pinnedMarkers = @{ 'App.tsx' = 5; 'p2japp.pas' = 5 }
$hardBan = 'XMLHttpRequest|WebSocket|EventSource|sendBeacon|localhost|' +
    '127\.0\.0\.1|file://|TRestHttpServer|THttpServer|' +
    'mormot\.net\.(server|client|http)'
$allowedMarkers = @{}

$bad = 0
$hits = @(Select-String -Path ($sdkFiles + $frontendFiles) -Pattern $network `
    -CaseSensitive:$false)
foreach ($h in $hits) {
    $leaf = Split-Path $h.Path -Leaf
    if (($h.Path -match '[\\/]frontend[\\/]src[\\/]') -and
        $pinnedMarkers.ContainsKey($leaf) -and
        ($h.Line -match $marker) -and
        ($h.Line -notmatch $hardBan)) {
        $urls = [regex]::Matches($h.Line, 'https?://[^\s''"]+')
        $allInvalid = $true
        foreach ($u in $urls) {
            if ($u.Value -notmatch '^https?://([a-z0-9-]+\.)*invalid([/''"]|$)') {
                $allInvalid = $false
            }
        }
        $isFetch = $h.Line -match 'fetch\s*\('
        if (($urls.Count -gt 0 -and $allInvalid) -or
            ($urls.Count -eq 0 -and $isFetch)) {
            if ($allowedMarkers.ContainsKey($leaf)) { $allowedMarkers[$leaf]++ }
            else { $allowedMarkers[$leaf] = 1 }
            continue
        }
    }
    Write-Host "FORBIDDEN CAP-5 NETWORK PATTERN: $($h.Path):$($h.LineNumber): $($h.Line.Trim())"
    $bad++
}
foreach ($k in $pinnedMarkers.Keys) {
    $got = 0
    if ($allowedMarkers.ContainsKey($k)) { $got = $allowedMarkers[$k] }
    if ($got -ne $pinnedMarkers[$k]) {
        Write-Host ("NAVSEC CARVE-OUT PIN MISMATCH: $k has $got permitted " +
            "probe lines, ratified $($pinnedMarkers[$k])")
        $bad++
    }
}
$bypass = @(Select-String -Path $frontendFiles -Pattern '__pweb_invoke' `
    -CaseSensitive:$false)
foreach ($h in $bypass) {
    Write-Host "FORBIDDEN RAW-PRIMITIVE BYPASS: $($h.Path):$($h.LineNumber): $($h.Line.Trim())"
    $bad++
}
if ($bad) { throw 'CAP-5 zero-network source proof failed' }
Write-Host 'CAP-5 zero-network source proof: PASS'
