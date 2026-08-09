# Binding surface + freeze-isolation checks (CAP-1). Headless, no compiler.
#
# 1. The generated unit declares EXACTLY the 17 pinned public C entry points
#    (no missing, no extras, no C++ wrapper API).
# 2. The raw layer contains no forbidden dependency (mORMot, React, Pas2JS,
#    QuickJS, SynLZ, TRest).
# 3. Phase-0 freeze isolation: pweb.rpc.intf.pas references no pweb.webview.*
#    unit; no frozen .intf unit references the raw binding.
#
# Exit code 0 = all green; 1 = any violation.

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Failures = @()

# --- 1. exact entry point surface -------------------------------------------
$Pinned = @(
    'webview_bind', 'webview_create', 'webview_destroy', 'webview_dispatch',
    'webview_eval', 'webview_get_native_handle', 'webview_get_window',
    'webview_init', 'webview_navigate', 'webview_return', 'webview_run',
    'webview_set_html', 'webview_set_size', 'webview_set_title',
    'webview_terminate', 'webview_unbind', 'webview_version'
) | Sort-Object

$Unit = Join-Path $RepoRoot 'src\lib\pweb.lib.webview.pas'
$Declared = Select-String -Path $Unit -Pattern "external LIB_WEBVIEW name _PU \+ '(\w+)'" |
    ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object

$MissingSyms = @($Pinned | Where-Object { $_ -notin $Declared })
$ExtraSyms   = @($Declared | Where-Object { $_ -notin $Pinned })
if ($MissingSyms) { $Failures += "missing entry points: $($MissingSyms -join ', ')" }
if ($ExtraSyms)   { $Failures += "unexpected entry points: $($ExtraSyms -join ', ')" }
if (-not $Failures) {
    Write-Host "surface: 17/17 pinned entry points declared, no extras"
}

# --- no C++ wrapper API ------------------------------------------------------
$CxxLeak = Select-String -Path $Unit -Pattern 'webview::|basic_result|noresult|native_library|user_script' -CaseSensitive
if ($CxxLeak) { $Failures += "C++ wrapper API leaked into the binding: $($CxxLeak[0].Line.Trim())" }

# --- 2. raw layer purity -----------------------------------------------------
$RawFiles = Get-ChildItem (Join-Path $RepoRoot 'src\lib') -Filter '*.pas'
foreach ($f in $RawFiles) {
    $Hit = Select-String -Path $f.FullName -Pattern 'mormot|TRest|react|pas2js|quickjs|synlz'
    if ($Hit) { $Failures += "forbidden dependency in $($f.Name): $($Hit[0].Line.Trim())" }
}
if ($Failures.Count -eq 0) { Write-Host "raw layer: no forbidden dependencies" }

# --- 3. Phase-0 freeze isolation ---------------------------------------------
# The isolation invariants are about CODE (uses clauses, identifiers), not
# about prose: the frozen units legitimately document the rules in comments.
# Strip comments before matching.
function Get-CodeOnly([string]$Path) {
    $t = Get-Content -Raw $Path
    $t = [regex]::Replace($t, '\{[^}]*\}', ' ')                      # { ... }
    $t = [regex]::Replace($t, '\(\*.*?\*\)', ' ', 'Singleline')      # (* ... *)
    $t = [regex]::Replace($t, '//[^\r\n]*', ' ')                     # // ...
    return $t
}

$RpcCode = Get-CodeOnly (Join-Path $RepoRoot 'src\rpc\pweb.rpc.intf.pas')
if ($RpcCode -match 'pweb\.webview') {
    $Failures += 'pweb.rpc.intf.pas code references a pweb.webview.* unit'
}

foreach ($intf in @('src\rpc\pweb.rpc.intf.pas', 'src\webview\pweb.webview.intf.pas', 'src\assets\pweb.assets.intf.pas')) {
    $Code = Get-CodeOnly (Join-Path $RepoRoot $intf)
    if ($Code -match 'pweb\.lib\.webview') {
        $Failures += "$intf code references the raw binding"
    }
    if ($Code -match 'WebView2|WKWebView|WebKitGTK|SynLZ|TZipRead|React') {
        $Failures += "$intf code names a platform/implementation type"
    }
}
if ($Failures.Count -eq 0) { Write-Host "freeze isolation: intact" }

# --- verdict -------------------------------------------------------------------
if ($Failures) {
    foreach ($f in $Failures) { Write-Error $f }
    exit 1
}
Write-Host 'check_binding_surface: PASS'
