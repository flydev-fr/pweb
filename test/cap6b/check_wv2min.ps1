# CAP-6b0 minimum-build cross-check: one threshold only. The Pascal
# PWEB_WV2_MIN_BUILD constant in the detector unit must equal the
# loader api_version pinned by the CAP-4W dependency patch, and both
# must be the ratified 1587 - so the detector's usability policy and
# the patched loader's reject/accept boundary can never drift apart.
#
# Usage: pwsh -File test/cap6b/check_wv2min.ps1

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$PatchFile = Join-Path $RepoRoot 'tools/cap4w/webview2-custom-scheme.patch'
$UnitFile = Join-Path $RepoRoot 'src/platform/windows/pweb.platform.webview2.runtime.pas'

$patch = Get-Content -LiteralPath $PatchFile -Raw
$pins = [regex]::Matches($patch,
    '\+\s*static constexpr unsigned int api_version = (\d+);')
if ($pins.Count -ne 1) {
    throw "CAP-4W patch must pin exactly one added api_version, found $($pins.Count)"
}
$patchMin = [int]$pins[0].Groups[1].Value

$pas = Get-Content -LiteralPath $UnitFile -Raw
if ($pas -notmatch 'PWEB_WV2_MIN_BUILD\s*=\s*(\d+)\s*;') {
    throw 'PWEB_WV2_MIN_BUILD constant not found in the detector unit'
}
$pasMin = [int]$Matches[1]

if ($pasMin -ne $patchMin) {
    throw "minimum drift: Pascal PWEB_WV2_MIN_BUILD=$pasMin vs patch api_version=$patchMin"
}
if ($pasMin -ne 1587) {
    throw "ratified minimum is 1587, both sides say $pasMin"
}
Write-Host "CAP-6b0 minimum cross-check PASS (build >= $pasMin on both sides)"

# URLs live only in lock files, never in swept sources: no web-scheme
# literal may appear in any CAP-6b0/CAP-6b1/CAP-6b2/CAP-6b3 Pascal
# source, nor in the Inno Setup projects or their shared includes (the
# setups embed their payload; nothing may point one at the network)
$pasFiles = @(
    (Join-Path $RepoRoot 'src/platform/windows/pweb.platform.webview2.runtime.pas'),
    (Join-Path $RepoRoot 'test/platform/pweb.test.webview2runtime.pas'),
    (Join-Path $RepoRoot 'test/cap6b/wv2probe.pas'),
    (Join-Path $RepoRoot 'src/platform/windows/pweb.platform.webview2.provision.pas'),
    (Join-Path $RepoRoot 'tools/setup/pwebwv2prov.pas'),
    (Join-Path $RepoRoot 'test/platform/pweb.test.wv2provision.pas'),
    (Join-Path $RepoRoot 'src/platform/windows/pweb.platform.webview2.fixed.pas'),
    (Join-Path $RepoRoot 'tools/setup/pwebwv2fixed.pas'),
    (Join-Path $RepoRoot 'test/platform/pweb.test.wv2fixed.pas'),
    (Join-Path $RepoRoot 'tools/setup/normal.iss'),
    (Join-Path $RepoRoot 'tools/setup/offline.iss'),
    (Join-Path $RepoRoot 'tools/setup/fixed.iss'),
    (Join-Path $RepoRoot 'tools/setup/pwebprovgate.issi'),
    (Join-Path $RepoRoot 'tools/setup/pwebappsetup.issi'),
    # CAP-6b4 split the release triple out of the identity include; the
    # new file is a setup source like any other and is swept like one
    (Join-Path $RepoRoot 'tools/setup/pwebapppayload.issi')
)
foreach ($f in $pasFiles) {
    if (-not (Test-Path -LiteralPath $f)) { throw "swept file missing: $f" }
}
$urlHits = @(Select-String -Path $pasFiles -Pattern 'https?://' `
    -CaseSensitive:$false)
if ($urlHits) {
    $urlHits | ForEach-Object {
        Write-Host "FORBIDDEN URL IN CAP-6b SOURCE: $($_.Path):$($_.LineNumber): $($_.Line.Trim())"
    }
    throw 'CAP-6b no-URL source proof failed'
}
Write-Host "CAP-6b no-URL source proof PASS ($($pasFiles.Count) sources clean)"

# CAP-6b2 offline hard invariant, static half (extended by CAP-6b3 to
# the fixed profile, whose invariant is stronger still - it provisions
# nothing at all): no download primitive may exist in any setup
# manifest, either shared include, or a production provisioning /
# fixed-runtime Pascal source - the embedded payload is the ONLY
# runtime source a target machine can ever see. Lock files and the
# build-side acquisition tooling (tools/get-*.ps1) are exempt as
# ratified: their URLs/downloads are build metadata, never target-side
# code.
$setupSources = @(
    (Join-Path $RepoRoot 'tools/setup/normal.iss'),
    (Join-Path $RepoRoot 'tools/setup/offline.iss'),
    (Join-Path $RepoRoot 'tools/setup/fixed.iss'),
    (Join-Path $RepoRoot 'tools/setup/pwebprovgate.issi'),
    (Join-Path $RepoRoot 'tools/setup/pwebappsetup.issi'),
    (Join-Path $RepoRoot 'tools/setup/pwebapppayload.issi')
)
$dlHits = @(Select-String -Path $setupSources -Pattern (
    'DownloadTemporaryFile|CreateDownloadPage|InternetOpen|' +
    'URLDownloadToFile|WinHttp|Invoke-WebRequest|WebClient') `
    -CaseSensitive:$false)
$prodSources = @(
    (Join-Path $RepoRoot 'src/platform/windows/pweb.platform.webview2.provision.pas'),
    (Join-Path $RepoRoot 'tools/setup/pwebwv2prov.pas'),
    (Join-Path $RepoRoot 'src/platform/windows/pweb.platform.webview2.fixed.pas'),
    (Join-Path $RepoRoot 'tools/setup/pwebwv2fixed.pas')
)
foreach ($f in $prodSources) {
    if (-not (Test-Path -LiteralPath $f)) { throw "swept file missing: $f" }
}
$dlHits += @(Select-String -Path $prodSources -Pattern (
    'URLDownloadToFile|WinHttp|InternetOpen|HttpSendRequest|' +
    'WebClient|Invoke-WebRequest|DownloadFile|DownloadString') `
    -CaseSensitive:$false)
if ($dlHits) {
    $dlHits | ForEach-Object {
        Write-Host "FORBIDDEN DOWNLOAD PRIMITIVE: $($_.Path):$($_.LineNumber): $($_.Line.Trim())"
    }
    throw 'CAP-6b2 no-download-primitive proof failed'
}
Write-Host ("CAP-6b2 no-download-primitive proof PASS " +
    "($($setupSources.Count) setup + $($prodSources.Count) production sources clean)")

# CAP-6b3 fixed-profile hard invariant, static half: the fixed profile
# must contain no Evergreen provisioning path whatsoever. Its manifest
# may not include the shared provisioning gate, may not name either
# Evergreen installer define, and its Pascal sources may not reference
# the provisioning orchestration (installer arguments, the bounded
# process runner or the provisioning run) - a fixed build that could
# execute an installer would have forked the whole profile.
$fixedSources = @(
    (Join-Path $RepoRoot 'tools/setup/fixed.iss'),
    # the shared identity include reaches the fixed profile through
    # fixed.iss, so a provisioning path added THERE would arrive here
    # untripped unless it is swept too - and CAP-6b4's shared payload
    # include reaches it the same way, from the fixed profile's own
    # [Files] order
    (Join-Path $RepoRoot 'tools/setup/pwebappsetup.issi'),
    (Join-Path $RepoRoot 'tools/setup/pwebapppayload.issi'),
    (Join-Path $RepoRoot 'src/platform/windows/pweb.platform.webview2.fixed.pas'),
    (Join-Path $RepoRoot 'tools/setup/pwebwv2fixed.pas')
)
foreach ($f in $fixedSources) {
    if (-not (Test-Path -LiteralPath $f)) { throw "swept file missing: $f" }
}
# the ban is on the provisioning MECHANISM, not on the word: a
# provenance comment naming the include is fine, an #include of it is
# not (anchored on the directive, so a documented cross-reference can
# never trip the gate and a real include can never slip past it)
$provHits = @(Select-String -Path $fixedSources -Pattern (
    '#include\s*"pwebprovgate\.issi"|PWEB_WV2_BOOTSTRAPPER|' +
    'PWEB_WV2_STANDALONE|PWEB_WV2_INSTALLER|PWEB_WV2_TIMEOUT_MS|' +
    'PWebWv2RunProcessBounded|PWebWv2ProvisionRun|' +
    'PWEB_WV2_BOOTSTRAPPER_ARGS') -CaseSensitive:$false)
if ($provHits) {
    $provHits | ForEach-Object {
        Write-Host "FORBIDDEN PROVISIONING PATH IN CAP-6b3 SOURCE: $($_.Path):$($_.LineNumber): $($_.Line.Trim())"
    }
    throw 'CAP-6b3 no-provisioning-path proof failed'
}
Write-Host ("CAP-6b3 no-provisioning-path proof PASS " +
    "($($fixedSources.Count) fixed-profile sources clean)")
