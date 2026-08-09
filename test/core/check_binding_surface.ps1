# Binding surface + freeze-isolation checks (CAP-1). Headless, no compiler.
#
# 1. The pinned api.h surface is extracted MECHANICALLY and diffed against
#    both the hardcoded pinned list and the binding's declared externals, so
#    a future pin bump cannot silently pass against stale lists.
# 2. The generated unit declares EXACTLY the pinned entry points (no missing,
#    no extras, no C++ wrapper API).
# 3. The raw layer contains no forbidden dependency (mORMot, React, Pas2JS,
#    QuickJS, SynLZ, TRest).
# 4. Phase-0 freeze isolation: pweb.rpc.intf.pas references no pweb.webview.*
#    unit; no frozen .intf unit references the raw binding or names a
#    platform/implementation type (code only -- comments/strings stripped).
#
# Findings are itemized on stderr WITHOUT terminating (Write-Error would be
# terminating under $ErrorActionPreference='Stop'); one final exit code.

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Failures = [System.Collections.Generic.List[string]]::new()

function Report-Section([string]$Name, [int]$Before) {
    if ($Failures.Count -eq $Before) { Write-Host "${Name}: OK" }
    else { Write-Host "${Name}: FAILED ($($Failures.Count - $Before) finding(s))" }
}

# The pinned public C ABI, kept in sync with api.h at the pinned commit.
$Pinned = @(
    'webview_bind', 'webview_create', 'webview_destroy', 'webview_dispatch',
    'webview_eval', 'webview_get_native_handle', 'webview_get_window',
    'webview_init', 'webview_navigate', 'webview_return', 'webview_run',
    'webview_set_html', 'webview_set_size', 'webview_set_title',
    'webview_terminate', 'webview_unbind', 'webview_version'
) | Sort-Object

# --- 1. mechanical surface from the pinned header ------------------------------
$s = $Failures.Count
$ApiH = Join-Path $RepoRoot 'deps\webview\core\include\webview\api.h'
if (-not (Test-Path $ApiH)) {
    $Failures.Add('pinned api.h missing -- run tools/get-webview.ps1 first (mechanical surface check requires it)')
    $FromHeader = @()
}
else {
    $FromHeader = Select-String -Path $ApiH -Pattern '^\s*WEBVIEW_API\b.*?\b(webview_\w+)\s*\(' |
        ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique
    foreach ($m in ($FromHeader | Where-Object { $_ -notin $Pinned })) {
        $Failures.Add("api.h declares '$m' but the pinned list does not contain it (stale list?)")
    }
    foreach ($m in ($Pinned | Where-Object { $_ -notin $FromHeader })) {
        $Failures.Add("pinned list contains '$m' but api.h does not declare it (stale list?)")
    }
    Write-Host "header surface: $($FromHeader.Count) WEBVIEW_API functions extracted from api.h (pinned list: $($Pinned.Count))"
}
Report-Section 'section 1 (mechanical header surface)' $s

# --- 2. exact entry point surface of the binding -------------------------------
$s = $Failures.Count
$Unit = Join-Path $RepoRoot 'src\lib\pweb.lib.webview.pas'
$Declared = Select-String -Path $Unit -Pattern "external LIB_WEBVIEW name _PU \+ '(\w+)'" |
    ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object

foreach ($m in ($Pinned | Where-Object { $_ -notin $Declared })) {
    $Failures.Add("binding is missing entry point: $m")
}
foreach ($m in ($Declared | Where-Object { $_ -notin $Pinned })) {
    $Failures.Add("binding declares unexpected entry point: $m")
}
$CxxLeak = Select-String -Path $Unit -Pattern 'webview::|basic_result|noresult|native_library|user_script' -CaseSensitive
if ($CxxLeak) { $Failures.Add("C++ wrapper API leaked into the binding: $($CxxLeak[0].Line.Trim())") }
Write-Host "binding surface: $($Declared.Count)/$($Pinned.Count) pinned entry points declared"
Report-Section 'section 2 (binding surface)' $s

# --- 3. raw layer purity --------------------------------------------------------
$s = $Failures.Count
$RawFiles = Get-ChildItem (Join-Path $RepoRoot 'src\lib') -Filter '*.pas'
foreach ($f in $RawFiles) {
    $Hit = Select-String -Path $f.FullName -Pattern 'mormot|TRest|react|pas2js|quickjs|synlz'
    if ($Hit) { $Failures.Add("forbidden dependency in $($f.Name): $($Hit[0].Line.Trim())") }
}
Report-Section 'section 3 (raw layer purity)' $s

# --- 4. Phase-0 freeze isolation ------------------------------------------------
# The isolation invariants are about CODE (uses clauses, identifiers), not
# about prose: the frozen units legitimately document the rules in comments.
# Strip string literals FIRST (so a literal containing '{' or '//' cannot
# swallow real code), then comments.
function Get-CodeOnly([string]$Path) {
    $t = Get-Content -Raw $Path
    $t = [regex]::Replace($t, "'([^'\r\n]|'')*'", "''")              # '...' literals
    $t = [regex]::Replace($t, '\{[^}]*\}', ' ')                      # { ... }
    $t = [regex]::Replace($t, '\(\*.*?\*\)', ' ', 'Singleline')      # (* ... *)
    $t = [regex]::Replace($t, '//[^\r\n]*', ' ')                     # // ...
    return $t
}

$s = $Failures.Count
$RpcCode = Get-CodeOnly (Join-Path $RepoRoot 'src\rpc\pweb.rpc.intf.pas')
if ($RpcCode -match 'pweb\.webview') {
    $Failures.Add('pweb.rpc.intf.pas code references a pweb.webview.* unit')
}

foreach ($intf in @('src\rpc\pweb.rpc.intf.pas', 'src\webview\pweb.webview.intf.pas', 'src\assets\pweb.assets.intf.pas')) {
    $Code = Get-CodeOnly (Join-Path $RepoRoot $intf)
    if ($Code -match 'pweb\.lib\.webview') {
        $Failures.Add("$intf code references the raw binding")
    }
    if ($Code -match 'WebView2|WKWebView|WebKitGTK|SynLZ|TZipRead|React') {
        $Failures.Add("$intf code names a platform/implementation type")
    }
}
Report-Section 'section 4 (freeze isolation)' $s

# --- verdict ---------------------------------------------------------------------
if ($Failures.Count -gt 0) {
    foreach ($f in $Failures) { [Console]::Error.WriteLine("FINDING: $f") }
    [Console]::Error.WriteLine("check_binding_surface: FAIL ($($Failures.Count) finding(s))")
    exit 1
}
Write-Host 'check_binding_surface: PASS'
exit 0
