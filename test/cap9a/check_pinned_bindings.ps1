# CAP-9A: THE PINNED mORMot DECLARATIONS PWEB RELIES ON, read from the pin.
#
# The 2026-09-16 mORMot pin move took two binding fixes this project reported
# upstream, and removed the PWeb-side workaround for the first:
#
#   9A-3  37fa86b4  JS_SetMaxStackSize takes JSRuntime, as the C side does.
#                   PWeb used to re-declare it; it now calls the pinned import.
#   9A-4  66d7d51c  the pas_* heap exports QuickJS calls with size_t are
#                   pointer-width.
#
# A fix that lives upstream is a fix upstream can revert, so this file asks the
# pinned sources the same questions on every leg. 9A-3 has a second guard in
# the compiler: pweb.script.quickjs.pas passes FEngine.rt, and FPC refuses a
# JSRuntime where a JSContext is declared. 9A-4 has none - the CAP-9 harnesses
# ran green at the old pin with the 32-bit declarations - so this is its only
# gate.
#
# EACH RULE IS PROVEN TO FIRE, on every run: the declaration the pin carries
# must match exactly once, and the same text with that declaration rewritten
# to its pre-fix form must match zero times. A rule whose pre-fix form cannot
# be built from the pinned text refuses too, because a negative leg nobody ran
# is not a gate.
#
# Checkout plus deps/mormot2 only: no toolchain, no network.
param([string]$MormotRoot = 'deps/mormot2')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$rules = @(
    @{ Key = '9A-3'; File = 'src/lib/mormot.lib.quickjs.pas'
       Want = '(?m)^procedure JS_SetMaxStackSize\(rt: JSRuntime; stack_size: PtrUInt\);'
       Revert = 'JS_SetMaxStackSize\(rt: JSRuntime;'; RevertTo = 'JS_SetMaxStackSize(ctx: JSContext;' }
    @{ Key = '9A-4'; File = 'src/lib/mormot.lib.static.pas'
       Want = '(?m)^function pas_malloc\(size: PtrU?Int\): pointer; cdecl;'
       Revert = 'pas_malloc\(size: PtrU?Int\)'; RevertTo = 'pas_malloc(size: cardinal)' }
    @{ Key = '9A-4'; File = 'src/lib/mormot.lib.static.pas'
       Want = '(?m)^function pas_realloc\(P: pointer; Size: PtrU?Int\): pointer; cdecl;'
       Revert = 'pas_realloc\(P: pointer; Size: PtrU?Int\)'; RevertTo = 'pas_realloc(P: pointer; Size: integer)' }
    @{ Key = '9A-4'; File = 'src/lib/mormot.lib.static.pas'
       Want = '(?m)^function pas_malloc_usable_size\(P: pointer\): PtrUInt; cdecl;'
       Revert = 'pas_malloc_usable_size\(P: pointer\): PtrUInt'; RevertTo = 'pas_malloc_usable_size(P: pointer): integer' }
)

$failures = 0
foreach ($r in $rules) {
    $path = Join-Path $MormotRoot $r.File
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host "[CAP-9A] $($r.Key): missing pinned source $path"
        $failures++
        continue
    }
    $text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $path).Path) -replace "`r`n", "`n"
    $hits = [regex]::Matches($text, $r.Want).Count
    $reverted = [regex]::Replace($text, $r.Revert, $r.RevertTo)
    $revertBuilt = ($reverted -cne $text)
    $revertHits = [regex]::Matches($reverted, $r.Want).Count
    $ok = ($hits -eq 1) -and $revertBuilt -and ($revertHits -eq 0)
    Write-Host ("[CAP-9A] pinned binding {0} {1}: pinned={2} reverted_form_built={3} reverted={4} -> {5}" -f
        $r.Key, $r.File, $hits, $revertBuilt, $revertHits, $(if ($ok) { 'PASS' } else { 'FAIL' }))
    if (-not $ok) { $failures++ }
}
if ($failures -gt 0) {
    Write-Host "[CAP-9A] pinned binding declarations FAILED: $failures rule(s) - the pin no longer carries a fix PWeb relies on, or the rule no longer reads it"
    exit 1
}
Write-Host "[CAP-9A] pinned binding declarations PASS - $($rules.Count) rules, each refused in its pre-fix form"
exit 0
