# CAP-11A: stage the leg's evidence for the collection block.
#
# Every gate on this leg has already written its record to disk. This copies the
# ratified per-class path union (test/cap11a/collection-paths.json, generated
# from the 61 upload steps the legacy ci.yml interleaved between gates) into
# build/cap11a/collect/<class>/, preserving each file's repository-relative path
# so an artifact's layout is the repository's layout - which is what makes
# docs/ci-migration.md's "old artifact -> path inside the new one" true by
# construction rather than by description.
#
# IT NEVER FAILS ON AN ABSENT PATH. A path union covering four targets names
# files only some of them produce, and a leg that failed at gate 40 legitimately
# has nothing from gate 80. Absence is recorded, not refused; the classes whose
# absence IS a defect (`evidence`) are refused by the upload step's
# `if-no-files-found: error` and by the aggregator, which are the two places that
# know what "required" means.
param(
    [Parameter(Mandatory = $true)][string]$Target,
    # THE DIAGNOSTICS CLASS IS THE `if: failure()` ONE. Staging it on a green
    # leg copies tens of megabytes nothing will ever upload, so the caller
    # passes the job's own status and a green leg stages the four classes that
    # are actually collected.
    [string]$JobStatus = 'success'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

$specFile = Join-Path $PSScriptRoot 'collection-paths.json'
if (-not (Test-Path -LiteralPath $specFile)) {
    throw "missing $specFile -- the ratified collection path union"
}
$spec = Get-Content -Raw -LiteralPath $specFile | ConvertFrom-Json

$root = Join-Path $repoRoot 'build/cap11a/collect'
if (Test-Path -LiteralPath $root) { Remove-Item -Recurse -Force $root }
New-Item -ItemType Directory -Force $root | Out-Null

$report = [ordered]@{}
$totalFiles = 0

foreach ($cls in $spec.PSObject.Properties.Name) {
    if ($cls -eq 'diagnostics' -and $JobStatus -eq 'success') {
        $report[$cls] = [ordered]@{ files = 0; bytes = 0; paths = @($spec.$cls).Count
                                    paths_absent = 0; skipped = 'leg green' }
        Write-Host "[cap11a] staged $cls skipped (the leg is green; nothing would upload it)"
        continue
    }
    $dest = Join-Path $root $cls
    New-Item -ItemType Directory -Force $dest | Out-Null
    $bytes = 0L
    $files = 0
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($spec.$cls)) {
        $rel = $p.TrimEnd('/', '\')
        # A declared path is a FILE, a DIRECTORY or a GLOB, and the three resolve
        # differently. MEASURED on the dev host: `Get-ChildItem -Path <file>
        # -Recurse` does NOT return that file - it treats the leaf as a filter
        # and searches the PARENT recursively, so the four declared evidence
        # paths staged twenty-seven files, including copies of `evidence.json`
        # from the aggregator's own selftest fixtures under `build/cap7f/
        # selftest/`. The aggregate then picks one BY NAME, and picking a
        # fixture instead of the real record is exactly the kind of quiet
        # wrongness this shard exists to remove.
        $items = @()
        try {
            if (Test-Path -LiteralPath $rel -PathType Leaf) {
                $items = @(Get-Item -LiteralPath $rel -Force)
            } elseif (Test-Path -LiteralPath $rel -PathType Container) {
                $items = @(Get-ChildItem -LiteralPath $rel -Force -Recurse -File -ErrorAction SilentlyContinue)
            } else {
                # a glob: it matches at the level it names, never below it
                $items = @(Get-ChildItem -Path $rel -Force -File -ErrorAction SilentlyContinue)
            }
        } catch { $items = @() }
        if ($items.Count -eq 0) { $missing.Add($p); continue }
        foreach ($f in $items) {
            $full = $f.FullName
            if (-not $full.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $r = $full.Substring($repoRoot.Length).TrimStart('\', '/')
            # never stage the collection into itself
            if ($r -replace '\\', '/' -like 'build/cap11a/collect/*') { continue }
            $out = Join-Path $dest $r
            $dir = Split-Path -Parent $out
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
            [System.IO.File]::Copy($full, $out, $true)
            $bytes += $f.Length
            $files++
        }
    }
    $totalFiles += $files
    $report[$cls] = [ordered]@{
        files        = $files
        bytes        = $bytes
        paths        = @($spec.$cls).Count
        paths_absent = $missing.Count
    }
    Write-Host ("[cap11a] staged {0,-12} files={1,-5} bytes={2,-12} absent_paths={3}" -f
        $cls, $files, $bytes, $missing.Count)
}

New-Item -ItemType Directory -Force (Join-Path $repoRoot 'build/cap11a') | Out-Null
$out = [ordered]@{
    schema  = 1
    target  = $Target
    classes = $report
    files   = $totalFiles
}
$json = ($out | ConvertTo-Json -Depth 5)
[System.IO.File]::WriteAllText((Join-Path $repoRoot 'build/cap11a/collection-bytes.json'),
    ($json -replace "`r`n", "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[cap11a] collection staged for $Target ($totalFiles files)"
