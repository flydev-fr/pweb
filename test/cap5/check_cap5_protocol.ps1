# CAP-5 wire-contract cross-check: the constants both SDKs hand-mirror
# from the native contract must never drift silently. Verified across
# src/rpc/pweb.rpc.intf.pas, sdk/typescript sources and
# sdk/pas2js/pweb.native.pas, plus the two host examples:
#   1. PWEB_PROTOCOL_VERSION;
#   2. the nine frozen error-code strings, in table order;
#   3. the informative status table, in the same order;
#   4. the native binding name (__pweb_invoke) the SDKs address and the
#      hosts Bind - the single constant connecting SDKs to every host.
$ErrorActionPreference = 'Stop'

function Get-Capture([string]$path, [string]$pattern) {
    $hit = Select-String -Path $path -Pattern $pattern
    if (-not $hit) { throw "pattern '$pattern' not found in $path" }
    return $hit[0].Matches[0].Groups[1].Value
}

# Extracts all single- or double-quoted strings from the lines of a
# declaration block, in order, starting at the line matching $startPat
# and ending at the first line containing ');'.
function Get-QuotedList([string]$path, [string]$startPat) {
    $lines = Get-Content $path
    $inBlock = $false
    $values = @()
    foreach ($line in $lines) {
        if (-not $inBlock) {
            if ($line -match $startPat) { $inBlock = $true } else { continue }
        }
        foreach ($m in [regex]::Matches($line, "['""]([a-z_]+)['""]")) {
            $values += $m.Groups[1].Value
        }
        if ($inBlock -and $line -match '\)\s*;' ) { break }
        if ($inBlock -and $line -match '\]\s*as const') { break }
    }
    if (-not $values) { throw "no quoted values under '$startPat' in $path" }
    return $values
}

# Extracts all integers >= 100 from a declaration block (status tables).
function Get-NumberList([string]$path, [string]$startPat, [string]$endPat) {
    $lines = Get-Content $path
    $inBlock = $false
    $values = @()
    foreach ($line in $lines) {
        if (-not $inBlock) {
            if ($line -match $startPat) { $inBlock = $true } else { continue }
        }
        $code = ($line -replace '//.*$', '') # ignore line comments
        foreach ($m in [regex]::Matches($code, '\b([1-9]\d{2})\b')) {
            $values += [int]$m.Groups[1].Value
        }
        if ($inBlock -and $line -match $endPat) { break }
    }
    if (-not $values) { throw "no numeric values under '$startPat' in $path" }
    return $values
}

$failures = @()

# --- 1. protocol version ----------------------------------------------
$native = [int](Get-Capture 'src/rpc/pweb.rpc.intf.pas' '^\s*PWEB_PROTOCOL_VERSION = (\d+);')
$ts = [int](Get-Capture 'sdk/typescript/src/handshake.ts' 'export const PWEB_PROTOCOL_VERSION = (\d+);')
$p2j = [int](Get-Capture 'sdk/pas2js/pweb.native.pas' '^\s*PWEB_PROTOCOL_VERSION = (\d+);')
if (($ts -ne $native) -or ($p2j -ne $native)) {
    $failures += "protocol version drift: native=$native ts=$ts pas2js=$p2j"
}

# --- 2. nine frozen code strings, table order -------------------------
$nativeCodes = Get-QuotedList 'src/rpc/pweb.rpc.intf.pas' '^\s*PWEB_ERROR_CODE_TEXT: array'
$tsCodes = Get-QuotedList 'sdk/typescript/src/types.ts' '^export const PWEB_ERROR_CODES = \['
$p2jCodes = Get-QuotedList 'sdk/pas2js/pweb.native.pas' '^\s*KNOWN_CODES: array'
foreach ($pair in @(@('typescript', $tsCodes), @('pas2js', $p2jCodes))) {
    if (($pair[1] -join ',') -cne ($nativeCodes -join ',')) {
        $failures += "$($pair[0]) code table drift: [$($pair[1] -join ',')] vs native [$($nativeCodes -join ',')]"
    }
}
if ($nativeCodes.Count -ne 9) { $failures += "native code table has $($nativeCodes.Count) entries, expected 9" }

# --- 3. informative status table, same order --------------------------
$nativeStatus = Get-NumberList 'src/rpc/pweb.rpc.intf.pas' '^\s*PWEB_ERROR_STATUS: array' '\)\s*;'
$tsStatus = Get-NumberList 'sdk/typescript/src/types.ts' '^export const PWEB_ERROR_STATUS' '^\};'
$p2jStatus = Get-NumberList 'sdk/pas2js/pweb.native.pas' '^\s*KNOWN_STATUS: array' '\)\s*;'
foreach ($pair in @(@('typescript', $tsStatus), @('pas2js', $p2jStatus))) {
    if (($pair[1] -join ',') -ne ($nativeStatus -join ',')) {
        $failures += "$($pair[0]) status table drift: [$($pair[1] -join ',')] vs native [$($nativeStatus -join ',')]"
    }
}
if ($nativeStatus.Count -ne 9) { $failures += "native status table has $($nativeStatus.Count) entries, expected 9" }

# --- 4. native binding name: SDK constants and host Bind literals -----
$tsName = Get-Capture 'sdk/typescript/src/invoke.ts' 'PWEB_NATIVE_BINDING_NAME = "([^"]+)"'
$p2jName = Get-Capture 'sdk/pas2js/pweb.native.pas' "PWEB_NATIVE_BINDING_NAME = '([^']+)'"
$reactBind = Get-Capture 'examples/04-react/reactapp.pas' "binding\.Bind\('([^']+)'"
$p2jBind = Get-Capture 'examples/05-pas2js/pas2jsapp.pas' "binding\.Bind\('([^']+)'"
$names = @($tsName, $p2jName, $reactBind, $p2jBind)
if (@($names | Sort-Object -Unique).Count -ne 1) {
    $failures += "binding name drift: ts=$tsName pas2js=$p2jName reactHost=$reactBind p2jHost=$p2jBind"
}

if ($failures) {
    $failures | ForEach-Object { Write-Host "VIOLATION: $_" }
    throw 'CAP-5 wire-contract cross-check failed'
}
Write-Host ("wire-contract cross-check: protocol $native, 9 codes, " +
    "9 statuses, binding name '$tsName' - all aligned")
