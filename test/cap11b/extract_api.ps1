# CAP-11B: the public C API of a webview/webview checkout, read MECHANICALLY.
#
# THIS IS THE DIFF'S ONLY SOURCE. The watcher never compares prose, release
# notes or commit messages: it parses the public C headers into a canonical
# model and compares two models. `docs/webview-upstream-semantics.md` fixes the
# scope of "the public C ABI" as `api.h` plus the public C headers it includes,
# and `webview.lock` names exactly those files in its `sha256:` rows - so the
# header set is the PINNED one, plus any `*.h` that appears beside them in a
# newer tree, which is how a new public header becomes news instead of a blind
# spot.
#
# A DECLARATION THIS PARSER CANNOT READ IS A REFUSAL, NEVER A SILENT PASS. The
# refusals travel in the model and the driver types the run `inconclusive`; a
# parser that quietly skipped an unfamiliar shape would report `unchanged`
# about a header it had not read.
#
#   pwsh test/cap11b/extract_api.ps1 -Root <checkout> -Out <model.json>
#
# Exit 0 = a model was produced with no refusal. Exit 2 = refusals (the model
# is still written, and carries them). Any other failure throws.

[CmdletBinding()]
param(
    # A webview/webview checkout root (the directory holding core/include).
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Out,
    # The lock whose `sha256:` rows name the pinned public header set.
    [string]$LockFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
if (-not $LockFile) { $LockFile = Join-Path $repoRoot 'webview.lock' }

$refusals = New-Object System.Collections.Generic.List[string]
function Refuse([string]$Text) { $script:refusals.Add($Text) }

# --- byte helpers -------------------------------------------------------------
# The recorded digests are over LF content (tools/get-webview.ps1 says why: git
# for Windows materialises these headers with CRLF, so a raw hash can only ever
# match one host). Everything here measures the same normalised bytes.
function Get-LfText([string]$Path) {
    return ([System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}
function Get-Sha256Utf8([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}
function Get-LfFileSha256([string]$Path) {
    # byte level, exactly reversing what autocrlf did on checkout
    $bytes = [IO.File]::ReadAllBytes($Path)
    $out = [byte[]]::new($bytes.Length)
    $n = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if (($bytes[$i] -eq 13) -and ($i + 1 -lt $bytes.Length) -and ($bytes[$i + 1] -eq 10)) { continue }
        $out[$n] = $bytes[$i]; $n++
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($out, 0, $n))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

# --- the header set -----------------------------------------------------------
# The lock's `sha256:` keys ARE the ratified public set. Reading them here
# rather than restating them means the two can never disagree.
$pinnedHeaders = @()
foreach ($line in (Get-Content -LiteralPath $LockFile)) {
    $t = $line.Trim()
    if ($t -match '^sha256:(\S+)\s*=') { $pinnedHeaders += $Matches[1] }
}
if ($pinnedHeaders.Count -eq 0) { throw "no sha256: header rows in $LockFile" }

$rootFull = (Resolve-Path -LiteralPath $Root).Path
$incDir = Join-Path $rootFull 'core/include/webview'
if (-not (Test-Path -LiteralPath $incDir -PathType Container)) {
    throw "not a webview checkout (no core/include/webview): $rootFull"
}

$headerSet = New-Object System.Collections.Generic.List[string]
foreach ($h in $pinnedHeaders) { [void]$headerSet.Add($h) }
# ANY `*.h` BESIDE THEM. A public header upstream added is additive surface the
# diff must see; one it removed is a missing-file refusal below.
foreach ($f in @(Get-ChildItem -LiteralPath $incDir -Filter '*.h' -File | Sort-Object Name)) {
    $rel = "core/include/webview/$($f.Name)"
    if (-not $headerSet.Contains($rel)) { [void]$headerSet.Add($rel) }
}
$headers = @($headerSet | Sort-Object)

# --- comment stripping --------------------------------------------------------
# A state machine rather than a regex: string and character literals must
# survive intact, because the version macros carry `"."` and `""`.
function Remove-CComments([string]$Text) {
    $sb = [Text.StringBuilder]::new($Text.Length)
    $i = 0; $n = $Text.Length
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($c -eq '"' -or $c -eq "'") {
            $quote = $c
            [void]$sb.Append($c); $i++
            while ($i -lt $n) {
                if ($Text[$i] -eq '\') {
                    if ($i + 1 -lt $n) { [void]$sb.Append($Text[$i]); [void]$sb.Append($Text[$i + 1]); $i += 2; continue }
                }
                [void]$sb.Append($Text[$i])
                if ($Text[$i] -eq $quote) { $i++; break }
                $i++
            }
            continue
        }
        if ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '*') {
            $i += 2
            while ($i + 1 -lt $n -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) {
                if ($Text[$i] -eq "`n") { [void]$sb.Append("`n") }
                $i++
            }
            $i += 2
            [void]$sb.Append(' ')
            continue
        }
        if ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '/') {
            while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        [void]$sb.Append($c); $i++
    }
    return $sb.ToString()
}

# --- type canonicalisation ----------------------------------------------------
# One spelling per type, so `char *x`, `char* x` and `char  *  x` are the same
# fact and a diff never fires on whitespace.
function Get-CanonType([string]$Raw) {
    $t = ($Raw -replace '\s+', ' ').Trim()
    $stars = 0
    while ($t.EndsWith('*')) { $stars++; $t = $t.Substring(0, $t.Length - 1).Trim() }
    # a leading `*` group can also sit against the name, already removed by the
    # caller; anything left is the base type
    $t = $t.Trim()
    if ($stars -gt 0) { return ($t + ' ' + ('*' * $stars)) }
    return $t
}

# Splits a C declarator into (type, name). `const char *url` -> ('const char *', 'url').
function Split-Declarator([string]$Decl) {
    $d = ($Decl -replace '\s+', ' ').Trim()
    if ($d -eq '' -or $d -eq 'void') { return $null }
    $m = [regex]::Match($d, '^(?<pre>.*?)(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?<arr>\[\s*[0-9]*\s*\])?$')
    if (-not $m.Success) { return $null }
    $pre = $m.Groups['pre'].Value
    $name = $m.Groups['name'].Value
    $arr = 0
    if ($m.Groups['arr'].Success) {
        $inner = ($m.Groups['arr'].Value -replace '[\[\]\s]', '')
        if ($inner -eq '') { $arr = -1 } else { $arr = [int]$inner }
    }
    if ($pre.Trim() -eq '') {
        # a bare identifier: an unnamed parameter whose type is that identifier
        return [pscustomobject]@{ Type = (Get-CanonType $name); Name = ''; Array = 0 }
    }
    return [pscustomobject]@{ Type = (Get-CanonType $pre); Name = $name; Array = $arr }
}

# --- parameter-list splitting at depth 0 --------------------------------------
function Split-TopLevel([string]$Text, [char]$Sep) {
    $parts = New-Object System.Collections.Generic.List[string]
    $depth = 0; $start = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -eq '(' -or $c -eq '[' -or $c -eq '{') { $depth++ }
        elseif ($c -eq ')' -or $c -eq ']' -or $c -eq '}') { $depth-- }
        elseif ($c -eq $Sep -and $depth -eq 0) {
            [void]$parts.Add($Text.Substring($start, $i - $start)); $start = $i + 1
        }
    }
    [void]$parts.Add($Text.Substring($start))
    # `.ToArray()`, never `@($list)`: on pwsh 7.6.5 `@()` over a generic List
    # throws `Argument types do not match`, and this script must behave
    # identically on the dev host and on all four runners.
    return , $parts.ToArray()
}

# --- the model ----------------------------------------------------------------
$functions = New-Object System.Collections.Generic.List[object]
$callbacks = New-Object System.Collections.Generic.List[object]
$enums     = New-Object System.Collections.Generic.List[object]
$structs   = New-Object System.Collections.Generic.List[object]
$typedefs  = New-Object System.Collections.Generic.List[object]
$macros    = New-Object System.Collections.Generic.List[object]
$headerRows = New-Object System.Collections.Generic.List[object]

# A function-pointer parameter: `void (*fn)(const char *id, void *arg)`.
$FNPTR = '^(?<ret>[A-Za-z_][A-Za-z0-9_ \*]*?)\s*\(\s*\*\s*(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*\)\s*\((?<args>.*)\)$'

function Read-Params([string]$Raw, [string]$Owner) {
    $result = New-Object System.Collections.Generic.List[object]
    $inner = ($Raw -replace '\s+', ' ').Trim()
    if ($inner -eq '' -or $inner -eq 'void') { return , $result.ToArray() }
    foreach ($p in (Split-TopLevel $inner ([char]',')))  {
        $piece = $p.Trim()
        if ($piece -eq '') { continue }
        $fp = [regex]::Match($piece, $FNPTR)
        if ($fp.Success) {
            $cbName = "$Owner`_$($fp.Groups['name'].Value)"
            $cbArgs = Read-Params $fp.Groups['args'].Value $cbName
            [void]$callbacks.Add([pscustomobject]@{
                name = $cbName
                ret  = (Get-CanonType $fp.Groups['ret'].Value)
                params = $cbArgs
                from = "$Owner.$($fp.Groups['name'].Value)"
            })
            [void]$result.Add([pscustomobject]@{
                type = $cbName; name = $fp.Groups['name'].Value; kind = 'callback' })
            continue
        }
        $d = Split-Declarator $piece
        if ($null -eq $d) { Refuse "$Owner`: unreadable parameter '$piece'"; continue }
        [void]$result.Add([pscustomobject]@{ type = $d.Type; name = $d.Name; kind = 'value' })
    }
    return , $result.ToArray()
}

foreach ($rel in $headers) {
    $path = Join-Path $rootFull $rel
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Refuse "public header missing from this tree: $rel"
        [void]$headerRows.Add([pscustomobject]@{ path = $rel; sha256_lf = ''; present = $false })
        continue
    }
    [void]$headerRows.Add([pscustomobject]@{
        path = $rel; sha256_lf = (Get-LfFileSha256 $path); present = $true })

    $raw = Get-LfText $path
    $src = Remove-CComments $raw
    # Line continuations are joined the way the preprocessor joins them, so a
    # macro upstream spread over five lines - WEBVIEW_VERSION_NUMBER is - yields
    # its whole value rather than the backslash it ends its first line with.
    $src = $src -replace '\\\n', ' '

    # --- macros: only the version block, which is the versioned ABI surface ----
    foreach ($m in [regex]::Matches($src, '(?m)^[ \t]*#[ \t]*define[ \t]+(WEBVIEW_VERSION_[A-Z_]+)[ \t]+(.*?)[ \t]*$')) {
        [void]$macros.Add([pscustomobject]@{
            name = $m.Groups[1].Value
            value = (($m.Groups[2].Value -replace '\s+', ' ').Trim()) })
    }

    # --- typedef enum / struct ------------------------------------------------
    foreach ($m in [regex]::Matches($src, '(?s)typedef\s+enum\s*\{(?<body>.*?)\}\s*(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*;')) {
        $members = New-Object System.Collections.Generic.List[object]
        $next = 0
        foreach ($piece in (Split-TopLevel $m.Groups['body'].Value ([char]','))) {
            $e = $piece.Trim()
            if ($e -eq '') { continue }
            $em = [regex]::Match($e, '^(?<n>[A-Za-z_][A-Za-z0-9_]*)\s*(=\s*(?<v>[-+]?\s*[0-9]+|[-+]?\s*0[xX][0-9a-fA-F]+))?$')
            if (-not $em.Success) {
                Refuse "$($m.Groups['name'].Value): unreadable enum member '$e'"
                continue
            }
            if ($em.Groups['v'].Success) {
                $vt = ($em.Groups['v'].Value -replace '\s', '')
                if ($vt -match '^[-+]?0[xX]') { $next = [Convert]::ToInt64($vt.TrimStart('+'), 16) }
                else { $next = [long]$vt }
            }
            [void]$members.Add([pscustomobject]@{ name = $em.Groups['n'].Value; value = $next })
            $next = $next + 1
        }
        [void]$enums.Add([pscustomobject]@{ name = $m.Groups['name'].Value; members = $members.ToArray() })
    }

    foreach ($m in [regex]::Matches($src, '(?s)typedef\s+struct\s*\{(?<body>.*?)\}\s*(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*;')) {
        $fields = New-Object System.Collections.Generic.List[object]
        foreach ($piece in (Split-TopLevel $m.Groups['body'].Value ([char]';'))) {
            $f = $piece.Trim()
            if ($f -eq '') { continue }
            $d = Split-Declarator $f
            if ($null -eq $d) { Refuse "$($m.Groups['name'].Value): unreadable field '$f'"; continue }
            [void]$fields.Add([pscustomobject]@{ type = $d.Type; name = $d.Name; array = $d.Array })
        }
        [void]$structs.Add([pscustomobject]@{ name = $m.Groups['name'].Value; fields = $fields.ToArray() })
    }

    # --- plain typedefs (`typedef void *webview_t;`) --------------------------
    foreach ($m in [regex]::Matches($src, '(?m)^[ \t]*typedef[ \t]+(?!enum|struct|union)(?<decl>[^;{}]+);')) {
        $d = Split-Declarator $m.Groups['decl'].Value
        if ($null -eq $d) { Refuse "unreadable typedef '$($m.Groups['decl'].Value.Trim())'"; continue }
        [void]$typedefs.Add([pscustomobject]@{ name = $d.Name; type = $d.Type })
    }

    # --- WEBVIEW_API entry points --------------------------------------------
    # From each `WEBVIEW_API` to the first `;` at paren depth 0. Everything in
    # between is one declaration however many lines upstream spread it over.
    $idx = 0
    while ($true) {
        $at = $src.IndexOf('WEBVIEW_API', $idx)
        if ($at -lt 0) { break }
        # skip the macro's own definition and its documentation of itself
        $lineStart = $src.LastIndexOf("`n", [Math]::Max($at - 1, 0))
        $lineHead = $src.Substring($lineStart + 1, $at - $lineStart - 1)
        if ($lineHead -match '#\s*(define|ifndef|ifdef|if|elif|undef)') { $idx = $at + 11; continue }

        $j = $at + 11; $depth = 0; $end = -1
        while ($j -lt $src.Length) {
            $c = $src[$j]
            if ($c -eq '(') { $depth++ }
            elseif ($c -eq ')') { $depth-- }
            elseif ($c -eq ';' -and $depth -eq 0) { $end = $j; break }
            elseif ($c -eq '{' -and $depth -eq 0) { break }
            $j++
        }
        if ($end -lt 0) {
            Refuse "WEBVIEW_API declaration at offset $at in $rel has no terminating ';'"
            $idx = $at + 11; continue
        }
        $decl = ($src.Substring($at + 11, $end - $at - 11) -replace '\s+', ' ').Trim()
        $idx = $end + 1

        $open = -1; $depth = 0
        for ($k = 0; $k -lt $decl.Length; $k++) {
            if ($decl[$k] -eq '(') { if ($depth -eq 0) { $open = $k }; $depth++ }
            elseif ($decl[$k] -eq ')') { $depth-- }
        }
        if ($open -lt 0 -or -not $decl.EndsWith(')')) {
            Refuse "unreadable WEBVIEW_API declaration in $rel`: '$decl'"
            continue
        }
        $head = $decl.Substring(0, $open).Trim()
        $args = $decl.Substring($open + 1, $decl.Length - $open - 2)
        $hm = [regex]::Match($head, '^(?<ret>.*?)(?<name>[A-Za-z_][A-Za-z0-9_]*)$')
        if (-not $hm.Success -or $hm.Groups['ret'].Value.Trim() -eq '') {
            Refuse "unreadable WEBVIEW_API head in $rel`: '$head'"
            continue
        }
        $fname = $hm.Groups['name'].Value
        [void]$functions.Add([pscustomobject]@{
            name = $fname
            ret = (Get-CanonType $hm.Groups['ret'].Value)
            params = (Read-Params $args $fname)
            header = $rel
        })
    }
}

# --- canonical ordering, so a digest is a fact about the API and not about
# --- the order upstream happened to write it in
$model = [ordered]@{
    schema    = 1
    headers   = @($headerRows | Sort-Object path)
    functions = @($functions | Sort-Object name)
    callbacks = @($callbacks | Sort-Object name)
    enums     = @($enums | Sort-Object name)
    structs   = @($structs | Sort-Object name)
    typedefs  = @($typedefs | Sort-Object name)
    macros    = @($macros | Sort-Object name)
    refusals  = @($refusals | Sort-Object)
}

# The digest covers the API, NOT the header digests: two trees whose bytes
# differ only in a comment must compare equal, which is the whole point of
# reading declarations instead of files.
$canon = New-Object System.Collections.Generic.List[string]
foreach ($f in $model.functions) {
    $ps = @($f.params | ForEach-Object { "$($_.type) $($_.name)" }) -join ', '
    [void]$canon.Add("fn|$($f.ret)|$($f.name)|$ps")
}
foreach ($c in $model.callbacks) {
    $ps = @($c.params | ForEach-Object { "$($_.type) $($_.name)" }) -join ', '
    [void]$canon.Add("cb|$($c.ret)|$($c.name)|$ps")
}
foreach ($e in $model.enums) {
    foreach ($mm in $e.members) { [void]$canon.Add("en|$($e.name)|$($mm.name)|$($mm.value)") }
}
foreach ($s in $model.structs) {
    foreach ($fl in $s.fields) { [void]$canon.Add("st|$($s.name)|$($fl.type)|$($fl.name)|$($fl.array)") }
}
foreach ($t in $model.typedefs) { [void]$canon.Add("td|$($t.name)|$($t.type)") }
foreach ($mc in $model.macros) { [void]$canon.Add("mc|$($mc.name)|$($mc.value)") }
$canonText = (($canon) -join "`n") + "`n"
$model['canonical'] = $canonText
$model['model_digest'] = Get-Sha256Utf8 $canonText

$outDir = Split-Path -Parent ([IO.Path]::GetFullPath($Out))
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force $outDir | Out-Null
}
[IO.File]::WriteAllText(
    ([IO.Path]::GetFullPath($Out)),
    (($model | ConvertTo-Json -Depth 12) -replace "`r`n", "`n"),
    [Text.UTF8Encoding]::new($false))

Write-Host ("[cap11b] {0}: {1} functions, {2} callbacks, {3} enums, {4} structs, {5} typedefs, {6} macros, digest {7}" -f `
    (Split-Path -Leaf $rootFull), $model.functions.Count, $model.callbacks.Count, $model.enums.Count, `
    $model.structs.Count, $model.typedefs.Count, $model.macros.Count, $model.model_digest.Substring(0, 12))
if ($refusals.Count -gt 0) {
    foreach ($r in $refusals) { Write-Host "[cap11b] REFUSAL: $r" }
    exit 2
}
exit 0
