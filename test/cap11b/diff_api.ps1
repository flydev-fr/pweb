# CAP-11B: the API diff, pinned -> head, from two extracted models.
#
# Every comparison here is between two canonical declaration strings produced
# by test/cap11b/extract_api.ps1. Nothing reads a release note, a tag or a
# commit message: `additive_only` is a property of the declarations, and the
# verdict the driver assigns rests on it.
#
# THE THREE OUTCOMES ARE DIFFERENT FACTS, and the report keeps them apart:
#   added    a name present in head and absent from the pin        (additive)
#   removed  a name present in the pin and absent from head        (breaking)
#   changed  a name in both whose canonical declaration differs    (breaking)
#
#   pwsh test/cap11b/diff_api.ps1 -Pinned <a.json> -Head <b.json> -Out <d.json>
#
# Always exits 0: a diff is news, never a failure.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Pinned,
    [Parameter(Mandatory = $true)][string]$Head,
    [Parameter(Mandatory = $true)][string]$Out
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$a = Get-Content -LiteralPath $Pinned -Raw | ConvertFrom-Json
$b = Get-Content -LiteralPath $Head   -Raw | ConvertFrom-Json

# --- one canonical string per named thing, in both models --------------------
function Get-Surface($Model) {
    $map = [ordered]@{}
    foreach ($f in $Model.functions) {
        $ps = @($f.params | ForEach-Object { "$($_.type) $($_.name)" }) -join ', '
        $map["function:$($f.name)"] = "$($f.ret) $($f.name)($ps)"
    }
    foreach ($c in $Model.callbacks) {
        $ps = @($c.params | ForEach-Object { "$($_.type) $($_.name)" }) -join ', '
        $map["callback:$($c.name)"] = "$($c.ret) (*$($c.name))($ps)"
    }
    foreach ($e in $Model.enums) {
        foreach ($mem in $e.members) {
            $map["enum_member:$($e.name).$($mem.name)"] = "$($mem.value)"
        }
        # the enum's own membership, so a member REMOVED is visible as a change
        # to the type as well as a removal of the member
        $names = @($e.members | ForEach-Object { $_.name }) -join ','
        $map["enum:$($e.name)"] = $names
    }
    foreach ($s in $Model.structs) {
        $fs = @($s.fields | ForEach-Object {
            if ($_.array -gt 0) { "$($_.type) $($_.name)[$($_.array)]" } else { "$($_.type) $($_.name)" }
        }) -join '; '
        $map["struct:$($s.name)"] = $fs
    }
    foreach ($t in $Model.typedefs) { $map["typedef:$($t.name)"] = $t.type }
    foreach ($mc in $Model.macros)  { $map["macro:$($mc.name)"] = $mc.value }
    return $map
}

$sa = Get-Surface $a
$sb = Get-Surface $b

$added   = New-Object System.Collections.Generic.List[object]
$removed = New-Object System.Collections.Generic.List[object]
$changed = New-Object System.Collections.Generic.List[object]

foreach ($k in @($sb.Keys | Sort-Object)) {
    if (-not $sa.Contains($k)) {
        $parts = $k -split ':', 2
        [void]$added.Add([pscustomobject]@{ kind = $parts[0]; name = $parts[1]; head = $sb[$k] })
    }
    elseif ($sa[$k] -cne $sb[$k]) {
        $parts = $k -split ':', 2
        [void]$changed.Add([pscustomobject]@{
            kind = $parts[0]; name = $parts[1]; pinned = $sa[$k]; head = $sb[$k] })
    }
}
foreach ($k in @($sa.Keys | Sort-Object)) {
    if (-not $sb.Contains($k)) {
        $parts = $k -split ':', 2
        [void]$removed.Add([pscustomobject]@{ kind = $parts[0]; name = $parts[1]; pinned = $sa[$k] })
    }
}

# A new public HEADER is additive surface, and is reported as such rather than
# hidden inside the declarations it happens to carry.
$pinnedHeaders = @($a.headers | ForEach-Object { $_.path })
$newHeaders = @($b.headers | Where-Object { $pinnedHeaders -cnotcontains $_.path } |
    ForEach-Object { $_.path })
$goneHeaders = @($a.headers | ForEach-Object { $_.path } |
    Where-Object { $bp = @($b.headers | ForEach-Object { $_.path }); $bp -cnotcontains $_ })

$diff = [ordered]@{
    schema        = 1
    pinned_digest = $a.model_digest
    head_digest   = $b.model_digest
    equal         = ($a.model_digest -ceq $b.model_digest)
    additive_only = (($removed.Count -eq 0) -and ($changed.Count -eq 0) -and ($added.Count -gt 0))
    added         = $added.ToArray()
    removed       = $removed.ToArray()
    changed       = $changed.ToArray()
    new_headers   = $newHeaders
    gone_headers  = $goneHeaders
    counts        = [ordered]@{
        added = $added.Count; removed = $removed.Count; changed = $changed.Count
    }
}

$outDir = Split-Path -Parent ([IO.Path]::GetFullPath($Out))
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force $outDir | Out-Null
}
[IO.File]::WriteAllText(([IO.Path]::GetFullPath($Out)),
    (($diff | ConvertTo-Json -Depth 10) -replace "`r`n", "`n"),
    [Text.UTF8Encoding]::new($false))

Write-Host ("[cap11b] diff: {0} added, {1} removed, {2} changed (equal={3}, additive_only={4})" -f `
    $added.Count, $removed.Count, $changed.Count, $diff.equal, $diff.additive_only)
foreach ($x in $removed.ToArray()) { Write-Host "  - REMOVED $($x.kind) $($x.name): $($x.pinned)" }
foreach ($x in $changed.ToArray()) {
    Write-Host "  ~ CHANGED $($x.kind) $($x.name)"
    Write-Host "      pinned: $($x.pinned)"
    Write-Host "      head:   $($x.head)"
}
foreach ($x in $added.ToArray()) { Write-Host "  + ADDED   $($x.kind) $($x.name): $($x.head)" }
exit 0
