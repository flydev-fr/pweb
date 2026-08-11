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
$network = 'fetch\s*\(|XMLHttpRequest|WebSocket|EventSource|' +
    'sendBeacon|localhost|127\.0\.0\.1|http://|https://|file://|' +
    'TRestHttpServer|THttpServer|mormot\.net\.(server|client|http)'

$bad = 0
$hits = @(Select-String -Path ($sdkFiles + $frontendFiles) -Pattern $network `
    -CaseSensitive:$false)
foreach ($h in $hits) {
    Write-Host "FORBIDDEN CAP-5 NETWORK PATTERN: $($h.Path):$($h.LineNumber): $($h.Line.Trim())"
    $bad++
}
$bypass = @(Select-String -Path $frontendFiles -Pattern '__pweb_invoke' `
    -CaseSensitive:$false)
foreach ($h in $bypass) {
    Write-Host "FORBIDDEN RAW-PRIMITIVE BYPASS: $($h.Path):$($h.LineNumber): $($h.Line.Trim())"
    $bad++
}
if ($bad) { throw 'CAP-5 zero-network source proof failed' }
Write-Host 'CAP-5 zero-network source proof: PASS'
