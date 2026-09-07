# CAP-11B: project an extracted C API model into a Pascal binding unit.
#
# WHY THIS EXISTS. `tools/regen-webview-binding.ps1` needs `ChetCLI.exe` at a
# hard-coded path on a Windows development host; no CI runner has it, and the
# watcher must not write into `src/` anyway. But the committed binding is a
# MECHANICAL function of the headers, and the constructs these six headers use
# are a small closed set. This reproduces that function into a WORKSPACE unit
# so `test/core/signature_pin.pas` and the paired ABI probes can be compiled
# against UPSTREAM HEAD's declarations rather than against ours.
#
# THE PROJECTOR IS CALIBRATED ON EVERY RUN, and that is the load-bearing part
# of the design: the watcher first projects the PINNED headers and compiles the
# pins against the result. If that fails, the tool is broken and the verdict is
# `inconclusive` - never `abi_break`. Only after the calibration passes is a
# failed head compile evidence about upstream.
#
# AN UNMAPPED C TYPE IS A REFUSAL. Guessing a Pascal spelling for a C type this
# table has never seen would be exactly the silent derivation the whole shard
# exists to avoid.
#
#   pwsh test/cap11b/project_binding.ps1 -Model <model.json> -OutDir <dir>
#
# Exit 0 = a unit was written. Exit 2 = refusals (nothing written).

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Model,
    [Parameter(Mandatory = $true)][string]$OutDir,
    # The committed unit whose platform block is reused verbatim.
    [string]$PlatformFrom
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
if (-not $PlatformFrom) { $PlatformFrom = Join-Path $repoRoot 'src/lib/pweb.lib.webview.pas' }

$refusals = New-Object System.Collections.Generic.List[string]
function Refuse([string]$Text) { $script:refusals.Add($Text) }

$m = Get-Content -LiteralPath $Model -Raw | ConvertFrom-Json

# --- the type table -----------------------------------------------------------
# Every entry is READ OFF the committed binding, not invented: `int` is
# `Integer` there, `unsigned int` is `Cardinal`, `void *` is `Pointer`,
# `const char *` is `PAnsiChar`. Nothing else is mapped, and nothing else is
# guessed.
$SCALARS = @{
    'int'          = 'Integer'
    'unsigned int' = 'Cardinal'
    'char'         = 'AnsiChar'
    'void *'       = 'Pointer'
    'const void *' = 'Pointer'
    'char *'       = 'PAnsiChar'
    'const char *' = 'PAnsiChar'
}

$enumNames   = @($m.enums     | ForEach-Object { $_.name })
$structNames = @($m.structs   | ForEach-Object { $_.name })
$typedefMap  = @{}
foreach ($t in $m.typedefs) { $typedefMap[$t.name] = $t.type }
$callbackNames = @($m.callbacks | ForEach-Object { $_.name })

function Test-Named([string]$Name) {
    return ($enumNames -ccontains $Name) -or ($structNames -ccontains $Name) -or
           ($typedefMap.ContainsKey($Name)) -or ($callbackNames -ccontains $Name)
}

# C type -> Pascal type. `$Where` only ever appears in a refusal message.
function Convert-Type([string]$CType, [string]$Where) {
    $t = ($CType -replace '\s+', ' ').Trim()
    if ($SCALARS.ContainsKey($t)) { return $SCALARS[$t] }
    if (Test-Named $t) { return $t }
    # `const <named> *` and `<named> *` become the generated pointer alias
    $pm = [regex]::Match($t, '^(const\s+)?(?<base>[A-Za-z_][A-Za-z0-9_]*)\s\*$')
    if ($pm.Success) {
        $base = $pm.Groups['base'].Value
        if (Test-Named $base) { return "P$base" }
    }
    Refuse "$Where`: unmapped C type '$CType'"
    return $null
}

# --- struct order: a by-value field needs its type declared first -------------
function Get-StructOrder {
    $remaining = New-Object System.Collections.Generic.List[object]
    foreach ($s in $m.structs) { [void]$remaining.Add($s) }
    $emitted = New-Object System.Collections.Generic.List[string]
    $order = New-Object System.Collections.Generic.List[object]
    $guard = 0
    while ($remaining.Count -gt 0) {
        $guard++
        if ($guard -gt 64) { Refuse 'struct dependency cycle or unresolvable order'; break }
        $progress = $false
        foreach ($s in @($remaining.ToArray() | Sort-Object name)) {
            $ready = $true
            foreach ($f in $s.fields) {
                $ft = ($f.type -replace '\s+', ' ').Trim()
                # only BY-VALUE references constrain the order; a pointer field
                # is satisfied by the forward declarations emitted above
                if (($structNames -ccontains $ft) -and -not ($emitted -ccontains $ft)) { $ready = $false }
            }
            if ($ready) {
                [void]$order.Add($s); [void]$emitted.Add($s.name)
                [void]$remaining.Remove($s); $progress = $true
            }
        }
        if (-not $progress) { Refuse 'struct dependency cycle'; break }
    }
    return , $order.ToArray()
}

# --- the platform block, taken VERBATIM from the committed unit ---------------
# It is platform plumbing (library file names per target), not API: the headers
# have nothing to say about it, and inventing it here would be this shard
# deciding what `LIB_WEBVIEW` means. Exact-match, exactly as
# tools/regen-webview-binding.ps1 does its own rewrites, so a changed shape
# throws instead of silently matching nothing.
$committed = ([System.IO.File]::ReadAllText($PlatformFrom) -replace "`r`n", "`n")
$pm = [regex]::Match($committed, '(?s)\ninterface\n\n(?<block>const\n  \{\$IF Defined\(WIN64\)\}.*?\{\$ENDIF\}\n)')
if (-not $pm.Success) {
    throw "the committed binding's platform block was not found in $PlatformFrom -- its shape changed"
}
$platformBlock = $pm.Groups['block'].Value

# --- emit ---------------------------------------------------------------------
$L = New-Object System.Collections.Generic.List[string]
function Emit([string]$Text) { [void]$L.Add($Text) }

Emit 'unit pweb.lib.webview;'
Emit ''
Emit '{ CAP-11B WATCHER PROJECTION -- NOT THE COMMITTED BINDING.'
Emit ''
Emit '  Produced by test/cap11b/project_binding.ps1 from the C headers of the'
Emit '  checkout the watcher measured. It exists only inside the watcher''s'
Emit '  workspace, is never written into src/, and is never committed. The'
Emit '  authority for the shipped binding stays src/lib/pweb.lib.webview.pas,'
Emit '  regenerated only by tools/regen-webview-binding.ps1. }'
Emit ''
Emit "{ model digest: $($m.model_digest) }"
Emit ''
Emit '{$MODE OBJFPC}{$H+}'
Emit '{$MINENUMSIZE 4}'
Emit '{$PACKRECORDS C}'
Emit ''
Emit 'interface'
Emit ''
foreach ($line in ($platformBlock -split "`n")) { Emit $line }

# enums: an Integer alias plus its members as consts, exactly as chet emits them
foreach ($e in ($m.enums | Sort-Object name)) {
    Emit 'type'
    Emit "  $($e.name) = Integer;"
    Emit "  P$($e.name) = ^$($e.name);"
    Emit ''
    Emit 'const'
    foreach ($mem in $e.members) { Emit "  $($mem.name) = $($mem.value);" }
    Emit ''
}

$structOrder = Get-StructOrder
if ($m.structs.Count -gt 0) {
    Emit 'type'
    Emit '  // Forward declarations'
    foreach ($s in ($m.structs | Sort-Object name)) { Emit "  P$($s.name) = ^$($s.name);" }
    Emit ''
    foreach ($s in $structOrder) {
        Emit "  $($s.name) = record"
        foreach ($f in $s.fields) {
            $pt = Convert-Type $f.type "$($s.name).$($f.name)"
            if ($null -eq $pt) { continue }
            if ($f.array -gt 0) {
                Emit "    $($f.name): array [0..$($f.array - 1)] of $pt;"
            }
            elseif ($f.array -lt 0) {
                Refuse "$($s.name).$($f.name): flexible array member is not projectable"
            }
            else {
                Emit "    $($f.name): $pt;"
            }
        }
        Emit '  end;'
        Emit ''
    }
}

foreach ($t in ($m.typedefs | Sort-Object name)) {
    $pt = Convert-Type $t.type "typedef $($t.name)"
    if ($null -eq $pt) { continue }
    Emit 'type'
    Emit "  $($t.name) = $pt;"
    Emit ''
}

foreach ($c in ($m.callbacks | Sort-Object name)) {
    $args = New-Object System.Collections.Generic.List[string]
    foreach ($p in $c.params) {
        $pt = Convert-Type $p.type "$($c.name).$($p.name)"
        if ($null -eq $pt) { continue }
        # `const char *` is spelled `const x: PAnsiChar` in the generated unit
        $prefix = if ($p.type -match '^const\s') { 'const ' } else { '' }
        [void]$args.Add("$prefix$($p.name): $pt")
    }
    $sig = ($args.ToArray() -join '; ')
    Emit 'type'
    if ($c.ret -eq 'void') {
        Emit "  $($c.name) = procedure($sig); cdecl;"
    }
    else {
        $rt = Convert-Type $c.ret "$($c.name) result"
        Emit "  $($c.name) = function($sig): $rt; cdecl;"
    }
    Emit ''
}

foreach ($f in ($m.functions | Sort-Object name)) {
    $args = New-Object System.Collections.Generic.List[string]
    foreach ($p in $f.params) {
        $pt = Convert-Type $p.type "$($f.name).$($p.name)"
        if ($null -eq $pt) { continue }
        $prefix = if ($p.type -match '^const\s') { 'const ' } else { '' }
        $pname = if ($p.name) { $p.name } else { 'unnamed' }
        [void]$args.Add("$prefix$pname`: $pt")
    }
    $sig = ($args.ToArray() -join '; ')
    $paren = if ($sig) { "($sig)" } else { '' }
    if ($f.ret -eq 'void') {
        Emit "procedure $($f.name)$paren; cdecl;"
    }
    else {
        $rt = Convert-Type $f.ret "$($f.name) result"
        if ($null -eq $rt) { continue }
        Emit "function $($f.name)$paren`: $rt; cdecl;"
    }
    Emit "  external LIB_WEBVIEW name _PU + '$($f.name)';"
    Emit ''
}

Emit 'implementation'
Emit ''
Emit 'end.'

if ($refusals.Count -gt 0) {
    foreach ($r in $refusals) { Write-Host "[cap11b] REFUSAL: $r" }
    Write-Host "[cap11b] projection refused ($($refusals.Count) finding(s)); nothing written"
    exit 2
}

$outFull = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force $outFull | Out-Null
$text = (($L.ToArray() -join "`n").TrimEnd("`n")) + "`n"
[IO.File]::WriteAllText((Join-Path $outFull 'pweb.lib.webview.pas'), $text, [Text.UTF8Encoding]::new($false))

# The two alias VIEW units are copied verbatim, never projected: they carry no
# ABI fact of their own, and that is exactly what makes them useful here - a
# symbol upstream removed makes THEM fail to compile, which is the drift.
foreach ($view in 'pweb.lib.webview.types.pas', 'pweb.lib.webview.errors.pas') {
    Copy-Item -Force -LiteralPath (Join-Path $repoRoot "src/lib/$view") `
        -Destination (Join-Path $outFull $view)
}

Write-Host "[cap11b] projected $($m.functions.Count) functions, $($m.callbacks.Count) callbacks, $($m.enums.Count) enums, $($m.structs.Count) structs -> $outFull"
exit 0
