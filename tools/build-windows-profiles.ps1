# CAP-6b4: the ONE entry point that produces all three Windows
# deployment artifacts of the SAME product.
#
#   dist/windows/normal/PWebRelease-Normal-Setup.exe
#   dist/windows/offline/PWebRelease-Offline-Setup.exe
#   dist/windows/fixed-runtime/PWebRelease-FixedRuntime-Setup.exe
#
# The three profiles are mutually exclusive MODES of one product (one
# AppId, one install directory, one HKCU profile marker), so there has
# to be one command that builds all of them and one manifest that says
# what came out. That is this script and dist/windows/release-index.json.
#
# WHAT THIS IS NOT. This is a PRIVATE repository build tool. It is not
# `pweb build`, it is not a CLI, and it deliberately ships nothing a
# user could invoke: CAP-10's user-facing CLI is out of scope here and
# is explicitly not being pre-designed by this file. The seam it leaves
# for CAP-10 is exactly one artifact - release-index.json - whose shape
# is deliberately minimal (profile, filename, bytes, sha256) so a later
# CLI can consume it without inheriting a private tool's interface.
#
# What it does, in order:
#   1. validates the pins with ZERO network (webview2-runtime.lock via
#      tools/get-webview2-runtime.ps1 -Validate) and refuses to build
#      on an incoherent lock - a partial artifact set is worse than no
#      artifact set
#   2. builds the three profiles IN ORDER (normal, offline, fixed):
#      cheapest first, so a defect in the shared includes fails in
#      ~30 s instead of after the ~690 MB fixed compile
#   3. writes dist/windows/release-index.json from the artifacts that
#      actually landed - measured, never predicted, and cross-checked
#      against the sha256 each profile's own build recorded, so a stale
#      artifact from an earlier run can never be published
#
# -IndexOnly rewrites the index from artifacts a previous run (or the
# per-profile CI build steps) already produced, building nothing. That
# is how CI gets an index without paying for a fourth set of compiles:
# the CAP-6b1/6b2/6b3 steps have already built all three.
#
# NETWORK. This orchestrator itself performs no download: its own lock
# validation is the zero-network -Validate path. But step 2 shells into
# the three per-profile build scripts, and THOSE do fetch - each acquires
# its pinned Microsoft artifact through tools/get-webview2-runtime.ps1
# (sha256 + Authenticode verified; the ~210 MB standalone and the ~290 MB
# cabinet are reused from deps/ only after re-passing that verification,
# while the small Evergreen Bootstrapper is re-fetched every run). So a
# full run needs network; -IndexOnly does not.
#
# It provisions nothing, executes no Microsoft installer, and installs
# nothing on the build machine.
#
# Preconditions: build/cap6/release assembled by
# test/cap6/run_cap6_gates.ps1, tools/build-webview-dll.ps1 run (the
# fixed profile bundles the pinned SDK loader from its cmake tree),
# fpc on PATH.
#
# Usage: pwsh -File tools/build-windows-profiles.ps1 [-IndexOnly]

param(
    [switch]$IndexOnly
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $RepoRoot
try {
    # the three profiles, in build order. Each names the manifest that
    # AUTHORS its basename (parsed here, never duplicated) and the build
    # script that produces it.
    $Profiles = @(
        @{
            Profile = 'normal'
            Iss     = 'tools/setup/normal.iss'
            Build   = 'test/cap6b1/build_normal_setup.ps1'
            DistDir = 'dist/windows/normal'
            LockFacts = 'build/cap6b1/lockfacts.psd1'
        },
        @{
            Profile = 'offline'
            Iss     = 'tools/setup/offline.iss'
            Build   = 'test/cap6b2/build_offline_setup.ps1'
            DistDir = 'dist/windows/offline'
            LockFacts = 'build/cap6b2/lockfacts.psd1'
        },
        @{
            Profile = 'fixed-runtime'
            Iss     = 'tools/setup/fixed.iss'
            Build   = 'test/cap6b3/build_fixed_setup.ps1'
            DistDir = 'dist/windows/fixed-runtime'
            LockFacts = 'build/cap6b3/lockfacts.psd1'
        }
    )

    # --- the basenames come from the manifests, one parse point --------------
    foreach ($p in $Profiles) {
        $issPath = Join-Path $RepoRoot $p.Iss
        if (-not (Test-Path $issPath)) { throw "setup manifest missing: $($p.Iss)" }
        $issText = Get-Content $issPath -Raw
        if ($issText -notmatch '(?m)^#define\s+PWEB_SETUP_BASENAME\s+"([^"]+)"\s*$') {
            throw "$($p.Iss) does not author the PWEB_SETUP_BASENAME define"
        }
        $p.Basename = $Matches[1]
        if ($p.Basename -ieq 'setup') {
            throw ("$($p.Iss) names its artifact 'setup' - every executable " +
                'named setup.exe is appcompat-shimmed into loading extra DLLs ' +
                'from its own directory')
        }
        # the profile NAME is authored in the same manifest and is the
        # value written to the HKCU marker: index and machine must agree
        if ($issText -notmatch '(?m)^#define\s+PWEB_PROFILE\s+"([^"]+)"\s*$') {
            throw "$($p.Iss) does not author the PWEB_PROFILE define"
        }
        if ($Matches[1] -cne $p.Profile) {
            throw ("$($p.Iss) declares profile '$($Matches[1])' but this " +
                "orchestrator expects '$($p.Profile)' - the ratified profile " +
                'name set drifted')
        }
        $p.Artifact = Join-Path $RepoRoot (Join-Path $p.DistDir "$($p.Basename).exe")
    }

    if (-not $IndexOnly) {
        # --- 1) the pins, with zero network ---------------------------------
        pwsh -NoProfile -File tools/get-webview2-runtime.ps1 -Validate
        if ($LASTEXITCODE -ne 0) {
            throw 'webview2-runtime.lock validation FAILED - refusing to build a partial artifact set'
        }
        pwsh -NoProfile -File test/cap6b/check_wv2lock.ps1
        if ($LASTEXITCODE -ne 0) { throw 'CAP-6b0 lock fixture matrix FAILED' }
        Write-Host 'CAP-6b4 orchestrator: locks validated (zero network)'

        # --- 2) the three profiles, cheapest first --------------------------
        foreach ($p in $Profiles) {
            Write-Host ''
            Write-Host "=== CAP-6b4 orchestrator: building the $($p.Profile) profile ==="
            pwsh -NoProfile -File $p.Build
            if ($LASTEXITCODE -ne 0) {
                throw "$($p.Profile) profile build FAILED ($($p.Build))"
            }
        }
    }

    # --- 3) the release index, from what actually landed --------------------
    # Deliberately minimal: profile, filename, bytes, sha256. No paths,
    # no versions, no timestamps, no build metadata - anything richer
    # would be a private tool's interface leaking into the one artifact
    # a future CAP-10 CLI is meant to consume.
    #
    # The document carries a SCHEMA VERSION so that seam actually works:
    # test/cap6b4/run_profile_isolation.ps1 freezes the entry shape for
    # schema 1, and a later CAP-10 that needs another field bumps the
    # schema instead of editing a CAP-6b4 gate.
    $IndexSchema = 1
    $entries = @()
    foreach ($p in $Profiles) {
        if (-not (Test-Path $p.Artifact)) {
            throw ("artifact missing for the $($p.Profile) profile: $($p.Artifact)" +
                $(if ($IndexOnly) { ' -- run without -IndexOnly, or run the per-profile build script first' } else { '' }))
        }
        $item = Get-Item -LiteralPath $p.Artifact
        $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $p.Artifact).Hash.ToLowerInvariant()
        # PUBLISH ONLY WHAT THIS BUILD PRODUCED. -IndexOnly measures
        # whatever is on disk, so without this the index could describe a
        # stale artifact from an earlier run perfectly accurately - and
        # the isolation gate would then re-measure the same stale bytes
        # and agree. Each profile's own build recorded the digest it
        # emitted; that is the authority.
        $factsFile = Join-Path $RepoRoot $p.LockFacts
        if (-not (Test-Path $factsFile)) {
            throw ("the $($p.Profile) profile has no exported lock facts " +
                "($($p.LockFacts)) - the artifact on disk cannot be attributed " +
                'to a build, so it will not be published')
        }
        $pf = Import-PowerShellDataFile $factsFile
        if (-not $pf.SetupSha) {
            throw ("$($p.LockFacts) records no SetupSha - rebuild the " +
                "$($p.Profile) profile so its artifact can be attributed")
        }
        if ($sha -cne "$($pf.SetupSha)".ToLowerInvariant()) {
            throw ("the $($p.Profile) artifact on disk hashes to $sha, but its " +
                "build recorded $($pf.SetupSha). Refusing to publish an artifact " +
                'this repository did not just produce - rebuild the profile')
        }
        $entries += [ordered]@{
            profile  = $p.Profile
            filename = $item.Name
            bytes    = $item.Length
            sha256   = $sha
        }
    }
    $IndexFile = Join-Path $RepoRoot 'dist/windows/release-index.json'
    New-Item -ItemType Directory -Force (Split-Path -Parent $IndexFile) | Out-Null
    ([ordered]@{ schema = $IndexSchema; profiles = $entries } |
        ConvertTo-Json -Depth 4) | Set-Content -Encoding utf8 $IndexFile

    foreach ($e in $entries) {
        Write-Host ("  {0,-13} {1,-42} {2,12} bytes  {3}" -f
            $e.profile, $e.filename, $e.bytes, $e.sha256)
    }
    Write-Host "CAP-6b4 release index written: $IndexFile"
    Write-Host 'CAP6B4_PROFILES_BUILD_PASS'
}
finally {
    Pop-Location
}
