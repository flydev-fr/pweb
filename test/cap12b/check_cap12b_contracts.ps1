# CAP-12B: the source contracts of the blob data plane.
#
# Checkout only - nothing here builds, runs or opens a window. Every check is
# a property of the SOURCE, and every one of them answers an adversarial
# question the shard was given rather than a shape somebody liked:
#
#   C1  can a store answer under `_pweb/`?          the branch precedes the
#                                                   asset store in all three
#                                                   adapters
#   C2  did the shard move the CSP?                 PWEB_NATIVE_CSP is
#                                                   byte-identical to the
#                                                   CAP-15A baseline
#   C3  did the shard add streaming, EventSource    no plane unit and no
#       or a media promise?                         adapter names any of them
#   C4  did the shard add an SDK upload API, or     neither SDK carries one,
#       a network primitive to an SDK?              and CAP-5's own pattern
#                                                   finds nothing in either
#   C5  can a page enumerate blobs?                 the store has no listing,
#                                                   and its tokens come from
#                                                   the unpredictable
#                                                   generator, not TLecuyer
#   C6  is IBlobStore what CAP-12A §5.1 ratified?   the three method sets,
#                                                   verbatim and in order
#   C7  is the plane layered where it says it is?   no webview, no rpc, no
#                                                   platform, no URI scheme
#                                                   in the units that promise
#                                                   not to name one
#   C8  can the pack refusal be overridden?         it takes no flag
#   C9  does the documentation still say            docs/kernel.md carries
#       `pweb://blob`?                              the reserved prefix
#
# AND THEN IT PERTURBS ITSELF. A contract check that has only ever been seen
# to pass has an unproven failure path; the self-test at the bottom breaks
# each load-bearing one - the branch order, the CSP, the SDK network bar and
# the streaming refusal - in a COPY of the tree and requires the
# check to refuse.
#
# Usage: pwsh test/cap12b/check_cap12b_contracts.ps1
#
# -SelfTestSandbox is not a mode anyone runs by hand: it is how the self-test
# invokes THIS script inside its perturbed copy, and all it does is stop the
# copy from running a self-test of its own - which would recurse forever.
param([switch]$SelfTestSandbox)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$violations = New-Object System.Collections.Generic.List[string]
$report = New-Object System.Collections.Generic.List[string]
function Violation([string]$m) {
    $script:violations.Add($m)
    Write-Host "CONTRACT VIOLATION: $m"
}
function Read_([string]$Path) {
    return ([System.IO.File]::ReadAllText((Join-Path $repoRoot $Path)) -replace "`r`n", "`n")
}

# Pascal comments removed, so a check never fires on prose ABOUT the thing it
# refuses - this file's own header would trip half of them otherwise.
function StripPascalComments([string]$Text) {
    $out = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ($c -eq '{') {
            while (($i -lt $Text.Length) -and ($Text[$i] -ne '}')) { $i++ }
            $i++
            continue
        }
        if (($c -eq '/') -and ($i + 1 -lt $Text.Length) -and ($Text[$i + 1] -eq '/')) {
            while (($i -lt $Text.Length) -and ($Text[$i] -ne "`n")) { $i++ }
            continue
        }
        if (($c -eq '(') -and ($i + 1 -lt $Text.Length) -and ($Text[$i + 1] -eq '*')) {
            $i += 2
            while (($i + 1 -lt $Text.Length) -and
                   -not (($Text[$i] -eq '*') -and ($Text[$i + 1] -eq ')'))) { $i++ }
            $i += 2
            continue
        }
        [void]$out.Append($c)
        $i++
    }
    return $out.ToString()
}

# the same idea for JavaScript and TypeScript: `//` to end of line and
# `/* ... */`, and nothing cleverer - a regular expression over a string
# literal containing a slash would be a parser, and this is a sweep
function StripJsComments([string]$Text) {
    $noBlock = [regex]::Replace($Text, '/\*[\s\S]*?\*/', ' ')
    return (($noBlock -split "`n" | ForEach-Object {
        $i = $_.IndexOf('//')
        if ($i -ge 0) { $_.Substring(0, $i) } else { $_ }
    }) -join "`n")
}

$INTF = 'src/assets/pweb.blobs.intf.pas'
$MEMORY = 'src/assets/pweb.blobs.memory.pas'
$PROTOCOL = 'src/assets/pweb.blobs.protocol.pas'
$ADAPTERS = @(
    'src/platform/windows/pweb.platform.webview2.pas',
    'src/platform/linux/pweb.platform.webkitgtk.pas',
    'src/platform/macos/pweb.platform.cocoa.pas'
)

foreach ($f in @($INTF, $MEMORY, $PROTOCOL) + $ADAPTERS) {
    if (-not (Test-Path (Join-Path $repoRoot $f))) { Violation "missing unit: $f" }
}

# --- C1: the reserved branch runs BEFORE the asset store ----------------------
# The ORDER is the whole reservation. A branch that ran after TryRead would
# let a bundle carrying `_pweb/...` answer for the runtime's own URL space,
# which is the one thing the namespace decision exists to prevent.
#
# It is measured as an OFFSET COMPARISON in the request path of each adapter:
# where the reserved test appears, against where the asset store is consulted.
foreach ($f in $ADAPTERS) {
    $code = StripPascalComments (Read_ $f)
    $branch = $code.IndexOf('PWebBlobIsReserved')
    $serve = $code.IndexOf('PWebBlobServe')
    # each adapter reaches the asset store through its own one-line resolver
    $storeCall = if ($f -like '*webview2*') { '.fStore.TryRead' }
        elseif ($f -like '*webkitgtk*') { 'PWebGtkResolveAssetUri(uri' }
        else { 'PWebCocoaResolveAssetUri(uri' }
    $store = $code.IndexOf($storeCall)
    if ($branch -lt 0) { Violation "C1: $f does not test the reserved prefix" }
    elseif ($serve -lt 0) { Violation "C1: $f does not call the translator" }
    elseif ($store -lt 0) { Violation "C1: $f no longer consults the asset store" }
    elseif ($branch -gt $store) {
        Violation ("C1: $f tests the reserved prefix AFTER it consults the " +
            'asset store -- a bundle could then answer under the runtime prefix')
    }
}
$report.Add('C1: all three adapters test the reserved prefix before the asset store')

# --- C2: the CSP did not move -------------------------------------------------
# PWEB_NATIVE_CSP is the premise the whole namespace decision rests on: an
# origin is scheme + host + port, and `connect-src ''self''` is what makes a
# second authority impossible. CAP-12B may not touch it, so the constant is
# compared to the ratified text rather than merely checked for existence.
$POLICY = 'src/security/pweb.navigation.policy.pas'
$policyText = Read_ $POLICY
$expectedCsp = @(
    "'default-src ''self''; base-uri ''none''; object-src ''none''; ' +",
    "'frame-src ''none''; frame-ancestors ''none''; form-action ''none''; ' +",
    "'connect-src ''self''; script-src ''self''; ' +",
    "'style-src ''self'' ''unsafe-inline''; img-src ''self'' data:; ' +",
    "'font-src ''self'' data:; media-src ''self''; worker-src ''none''; ' +",
    "'manifest-src ''self'''"
) -join "`n    "
if (-not $policyText.Contains($expectedCsp)) {
    Violation ('C2: PWEB_NATIVE_CSP is not the ratified constant -- CAP-12B ' +
        'may not move it, and the namespace decision rests on it')
}
# and no unit of this shard may spell a directive of its own
foreach ($f in @($INTF, $MEMORY, $PROTOCOL)) {
    $code = StripPascalComments (Read_ $f)
    foreach ($needle in 'connect-src', 'default-src', 'Content-Security-Policy') {
        if ($code.Contains($needle)) {
            Violation ("C2: $f spells ${needle}: the policy has ONE home and " +
                'the plane transports it rather than restating it')
        }
    }
}
$report.Add('C2: PWEB_NATIVE_CSP is the ratified constant and the plane spells no directive')

# --- C3: no streaming, no EventSource, no media promise -----------------------
# CAP-12A §4 REFUSED all three on measurement: WebView2 buffers a response
# body entirely and WebKitGTK cannot play a custom-scheme media resource, so
# a plane that offered any of them would be promising what one engine cannot
# keep. This refuses the shapes, in the units that would have to carry them.
foreach ($f in @($INTF, $MEMORY, $PROTOCOL) + $ADAPTERS) {
    $code = StripPascalComments (Read_ $f)
    foreach ($needle in 'text/event-stream', 'EventSource', 'Transfer-Encoding',
                        'chunked') {
        if ($code.Contains($needle)) {
            Violation ("C3: $f names ${needle}: the plane is Range-based, and " +
                'streaming was refused by measurement rather than deferred')
        }
    }
}
$report.Add('C3: no streaming, no EventSource, no chunked transfer anywhere in the plane')

# --- C4: the SDK read surface is a TYPE, and nothing else ----------------------
# CAP-12A §6.2 ratified a typed-array PUT to the blob plane as the transport
# and left the SDK that drives it to CAP-12C, so there is no write surface.
#
# AND THERE IS NO READER EITHER, which is a correction with a hosted run
# behind it. The first CAP-12B SDK carried a `readBlob` that loaded
# `handle.url` itself, and CAP-5's zero-network sweep - whose bar is that no
# SDK source contains a browser network primitive AT ALL - refused it on the
# Windows leg of run 35102099474. The sweep was right: a blob is an ordinary
# same-origin resource, the page loads it the way it loads its own assets,
# and an SDK helper that did it instead would be a network entry point this
# package promised never to have. What ships is the handle type, which is
# where the runtime-built URL travels.
$tsBlob = Read_ 'sdk/typescript/src/blob.ts'
foreach ($needle in 'createBlob', 'putBlob', 'writeBlob', 'uploadBlob',
                    'native.blobs.create', 'readBlob') {
    if ($tsBlob.Contains($needle)) {
        Violation ("C4: the TypeScript SDK names ${needle}: the blob surface " +
            'is the handle type - no writer until CAP-12C, and no reader ever')
    }
}
if (-not $tsBlob.Contains('export interface PWebBlobHandle')) {
    Violation 'C4: the TypeScript SDK carries no PWebBlobHandle'
}
$p2j = Read_ 'sdk/pas2js/pweb.native.pas'
foreach ($needle in 'PWebCreateBlob', 'PWebPutBlob', 'PWebWriteBlob',
                    'PWebUploadBlob', 'PWebReadBlob') {
    if ($p2j.Contains($needle)) {
        Violation ("C4: the Pas2JS SDK names ${needle}: the blob surface is " +
            'the handle type - no writer until CAP-12C, and no reader ever')
    }
}
if (-not $p2j.Contains('TPWebBlobHandle = class external')) {
    Violation 'C4: the Pas2JS SDK carries no TPWebBlobHandle'
}
# THE CAP-5 PATTERN, READ BACK OUT OF ITS OWN SCRIPT and applied here, so
# this gate refuses the exact shape that sweep refuses without keeping a
# second copy of it. Comments are NOT stripped, because CAP-5 does not strip
# them either: a comment spelling the primitive fails that gate too.
$cap5Text = Read_ 'test/cap5/check_cap5_nonetwork.ps1'
$cap5Match = [regex]::Match($cap5Text, '(?s)\$network = ((?:''[^'']*''\s*\+?\s*)+)')
if (-not $cap5Match.Success) {
    Violation 'C4: the CAP-5 $network pattern could not be parsed out of its script'
} else {
    $cap5Pattern = -join ([regex]::Matches($cap5Match.Groups[1].Value, "'([^']*)'") |
        ForEach-Object { $_.Groups[1].Value })
    $cap5Rx = [regex]::new($cap5Pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($pair in @(@('sdk/typescript/src/blob.ts', $tsBlob),
                        @('sdk/pas2js/pweb.native.pas', $p2j))) {
        $lineNo = 0
        foreach ($ln in ($pair[1] -split "`n")) {
            $lineNo++
            if ($cap5Rx.IsMatch($ln)) {
                Violation ("C4: $($pair[0]):${lineNo} carries a network " +
                    "primitive CAP-5 refuses: $($ln.Trim())")
            }
        }
    }
}
# NEITHER SDK BUILDS A BLOB URL. `handle.url` comes from the runtime, which
# is the only place that knows both spellings; an SDK that concatenated the
# prefix would be an answer a page could be talked into changing.
# COMMENTS STRIPPED FIRST, exactly as CAP-15B's own origin sweep does it: a
# file is allowed to EXPLAIN that the runtime serves these URLs, and this
# check is about what the CODE constructs.
foreach ($pair in @(@('sdk/typescript/src/blob.ts', (StripJsComments $tsBlob)),
                    @('sdk/pas2js/pweb.native.pas', (StripPascalComments $p2j)))) {
    if ($pair[1] -match 'pweb://app') {
        Violation ("C4: $($pair[0]) spells the privileged origin in CODE: the " +
            'URL comes from the runtime and is never derived in an SDK')
    }
}
$report.Add('C4: both SDKs carry the handle type, no reader, no writer, no network primitive, no URL')

# --- C5: no enumeration, and an unpredictable token ---------------------------
# A token is an identifier and never an authorization - the owner is checked
# too - but it must not be an enumeration either, and TLecuyer is predictable
# from its own output.
$memCode = StripPascalComments (Read_ $MEMORY)
if (-not $memCode.Contains('Random128')) {
    Violation ('C5: the store does not mint tokens with Random128 -- 128 bits ' +
        'of handle entropy has to come from an unpredictable generator')
}
foreach ($needle in 'TLecuyer', 'RandomLecuyer', 'Random32', 'RandomGuid') {
    if ($memCode.Contains($needle)) {
        Violation ("C5: the store names ${needle}: a predictable generator " +
            'makes a token space walkable')
    }
}
$intfCode = StripPascalComments (Read_ $INTF)
foreach ($needle in 'ListBlobs', 'EnumBlobs', 'AllTokens', 'Tokens:') {
    if ($intfCode.Contains($needle)) {
        Violation ("C5: IBlobStore offers ${needle}: the plane has no listing, " +
            'because a listing is an enumeration with better manners')
    }
}
$report.Add('C5: tokens come from the unpredictable generator and nothing lists them')

# --- C6: the ratified method sets, verbatim ------------------------------------
# CAP-12A §5.1 IS the Phase-4b entry ratification. These are its signatures,
# in its order; a method added, removed or reordered here is a contract
# change and must be ratified rather than committed.
$ratified = @(
    'function Info(out Blob: TBlobInfo): Boolean;',
    'function ReadAt(Offset: Int64; Buffer: Pointer; Count: Integer): Integer;',
    'function Append(Buffer: Pointer; Count: Integer): Boolean;',
    'function Seal(const ContentType: RawUtf8; out Token: RawUtf8): Boolean;',
    'procedure Abandon;',
    'function CreateBlob(const Owner: RawUtf8; SizeHint: Int64;',
    'function OpenBlob(const Owner: RawUtf8; const Token: RawUtf8;',
    'function Release(const Owner: RawUtf8; const Token: RawUtf8): Boolean;',
    'function ReleaseOwner(const Owner: RawUtf8): Integer;',
    'function Stats(out Count: Integer; out Bytes: Int64): Boolean;'
)
$lastAt = -1
foreach ($sig in $ratified) {
    $at = $intfCode.IndexOf($sig)
    if ($at -lt 0) {
        Violation "C6: the ratified signature is missing or reworded: $sig"
    } elseif ($at -lt $lastAt) {
        Violation "C6: the ratified method order moved at: $sig"
    } else { $lastAt = $at }
}
# TBlobInfo's four fields, in CAP-12A's order
foreach ($field in 'Size: Int64;', 'ContentType: RawUtf8;', 'Owner: RawUtf8;',
                   'Sealed: Boolean;') {
    if (-not $intfCode.Contains($field)) {
        Violation "C6: TBlobInfo no longer carries $field"
    }
}
$report.Add('C6: IBlobStore/IBlobReader/IBlobWriter are CAP-12A §5.1 verbatim')

# --- C7: the layering the units promise ----------------------------------------
# `IBlobStore` is decoupled from the URI scheme - the SPEC's own rule - and
# the translator is the ONE unit that knows both spellings. The adapters keep
# the CAP-4 isolation compile, so the translator may not pull crypt in.
foreach ($needle in 'pweb://', '_pweb', 'Range', 'IStream', 'GInputStream',
                    'NSData', 'TFileName') {
    if ($intfCode.Contains($needle)) {
        Violation ("C7: $INTF names ${needle}: the contract is decoupled from " +
            'the URI scheme, the transport and the filesystem')
    }
}
foreach ($needle in 'pweb://', '_pweb') {
    if ($memCode.Contains($needle)) {
        Violation "C7: $MEMORY names ${needle}: a store knows no URL"
    }
}
$protoUses = ((Read_ $PROTOCOL) -split 'implementation')[0]
foreach ($needle in 'mormot.crypt', 'pweb.lib.webview', 'pweb.rpc',
                    'pweb.platform') {
    if ($protoUses.Contains($needle)) {
        Violation ("C7: $PROTOCOL uses ${needle}: the three adapters compile " +
            'it under the CAP-4 isolation path, which carries none of those')
    }
}
foreach ($f in @($INTF, $MEMORY, $PROTOCOL)) {
    $uses = ((Read_ $f) -split 'implementation')[0]
    foreach ($needle in 'pweb.webview', 'pweb.platform', 'mormot.net') {
        if ($uses.Contains($needle)) {
            Violation "C7: $f uses ${needle}"
        }
    }
}
$report.Add('C7: the contract names no URI scheme, no transport and no path')

# --- C8: the pack refusal takes no override -----------------------------------
$bundler = Read_ 'tools/bundler/pwebbundle.pas'
if (-not $bundler.Contains('reserved_prefix_in_bundle')) {
    Violation 'C8: pwebbundle does not refuse the reserved prefix'
}
$bundlerCode = StripPascalComments $bundler
foreach ($needle in '--allow-pweb', '--include-pweb', '--allow-reserved') {
    if ($bundlerCode.Contains($needle)) {
        Violation ("C8: pwebbundle offers ${needle}: the handler will not serve " +
            'it, so a flag that packed it anyway would be a lie told at build time')
    }
}
$report.Add('C8: the pack-time reservation has no override')

# --- C9: the documentation says what the product does --------------------------
$kernel = Read_ 'docs/kernel.md'
if (-not $kernel.Contains('pweb://app/_pweb/blob/')) {
    Violation 'C9: docs/kernel.md does not state the reserved prefix'
}
if ($kernel -match '(?m)^- JSON is the control plane, `pweb://blob` the data plane') {
    Violation ('C9: docs/kernel.md still states the pre-CAP-12A spelling as the ' +
        'invariant -- the invariant survives, the spelling does not')
}
$report.Add('C9: docs/kernel.md carries the reserved prefix')

# --- the negative self-test ----------------------------------------------------
# THREE PERTURBATIONS, each of which this script must refuse, applied to a
# COPY of the tree so the working tree is never touched. The three chosen are
# the load-bearing ones: the branch order, the CSP, and the streaming refusal.
$sandbox = Join-Path $repoRoot 'build/cap12b/contract-selftest'
$refused = 0
$legs = @(
    @{ name = 'the asset store is consulted before the reserved branch'
       file = 'src/platform/windows/pweb.platform.webview2.pas'
       from = '    parsed := PWebParseAppUri(uri, logical);'
       to   = "    parsed := PWebParseAppUri(uri, logical);`n" +
              '    fOwner.fStore.TryRead(logical, asset);'
       say  = 'C1:' },
    @{ name = 'the reserved branch is removed altogether'
       file = 'src/platform/windows/pweb.platform.webview2.pas'
       from = '       PWebBlobIsReserved(logical) then'
       to   = '       False then'
       say  = 'C1:' },
    @{ name = 'the CSP is weakened'
       file = 'src/security/pweb.navigation.policy.pas'
       from = "'connect-src ''self''; script-src ''self''; ' +"
       to   = "'connect-src *; script-src ''self''; ' +"
       say  = 'C2:' },
    @{ name = 'the TypeScript SDK grows a network primitive'
       file = 'sdk/typescript/src/blob.ts'
       from = 'export function isPWebBlobHandle('
       to   = "export const load = (u: string) => fetch(u);`nexport function isPWebBlobHandle("
       say  = 'C4:' },
    @{ name = 'the plane grows a streaming content type'
       file = 'src/assets/pweb.blobs.protocol.pas'
       from = "PWEB_BLOB_UPLOAD_REFUSAL = 'blob_upload_not_enabled';"
       to   = "PWEB_BLOB_UPLOAD_REFUSAL = 'blob_upload_not_enabled';`n  PWEB_BLOB_STREAM_TYPE = 'text/event-stream';"
       say  = 'C3:' }
)
if ($SelfTestSandbox) { $legs = @() }
if ((Test-Path $sandbox) -and -not $SelfTestSandbox) {
    Remove-Item -Recurse -Force $sandbox
}
foreach ($leg in $legs) {
    New-Item -ItemType Directory -Force $sandbox | Out-Null
    foreach ($d in 'src', 'tools', 'docs', 'sdk/typescript/src', 'sdk/pas2js',
                'test/cap12b', 'test/cap5') {
        $dest = Join-Path $sandbox $d
        New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
        Copy-Item -Recurse -Force (Join-Path $repoRoot $d) $dest
    }
    $p = Join-Path $sandbox $leg.file
    $t = [System.IO.File]::ReadAllText($p) -replace "`r`n", "`n"
    if (-not $t.Contains($leg.from)) {
        Write-Host "  ACCEPTED $($leg.name) -- the perturbation no longer applies"
        continue
    }
    [System.IO.File]::WriteAllText($p, $t.Replace($leg.from, $leg.to))
    $out = & pwsh -NoProfile -File (Join-Path $sandbox 'test/cap12b/check_cap12b_contracts.ps1') `
        -SelfTestSandbox 2>&1 | Out-String
    if (($LASTEXITCODE -ne 0) -and ($out -match [regex]::Escape($leg.say))) {
        Write-Host "  refused  $($leg.name)"
        $refused++
    } else {
        Write-Host "  ACCEPTED $($leg.name) -- exit=$LASTEXITCODE"
    }
    Remove-Item -Recurse -Force $sandbox
}
if ((Test-Path $sandbox) -and -not $SelfTestSandbox) {
    Remove-Item -Recurse -Force $sandbox
}
if (-not $SelfTestSandbox) {
    if ($refused -ne $legs.Count) {
        Violation ("the negative self-test: $refused/$($legs.Count) perturbations " +
            'were refused -- a contract check that cannot fail is not a check')
    }
    $report.Add("self-test: $refused/$($legs.Count) perturbations refused")
}

# --- verdict -------------------------------------------------------------------
foreach ($line in $report) { Write-Host "[cap12b] $line" }
if ($violations.Count -gt 0) {
    Write-Host "[cap12b] CONTRACTS FAILED: $($violations.Count) violation(s)"
    exit 1
}
Write-Host '[cap12b] contracts PASS'
exit 0
