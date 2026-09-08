param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath,
    [Parameter(Mandatory = $true)]
    [string]$MapPath,
    [string]$DumpbinPath
)

# CAP-3U binary gate, over the PRISTINE PINNED DEPENDENCY.
#
# Until the 2026-09-08 mORMot pin move this gate measured a hand-written
# ml64 object that tools/patch-cap3u.ps1 linked into mORMot's own source:
# FPC 3.2.2 Win64 emitted NO unwind metadata for mORMot's private CallMethod
# assembler, so an exception raised inside an interface-based service killed
# the process instead of unwinding. Upstream fixed it in 896f1c1c
# ("core: Win64 requires unwinding information for its asm stub"), citing the
# report this repository filed, and the pin now carries that commit. The
# patch, the ASM source and the generated OBJ are gone.
#
# WHAT REPLACES THEM IS THIS SAME GATE, ASKING THE SAME QUESTIONS OF THE
# COMPILER'S OWN OUTPUT. A fix that lives upstream is a fix somebody can
# revert upstream, and a `.seh_*` directive an assembler silently ignored
# would look exactly like a fix that worked. So the five assertions the OBJ
# had to satisfy are now made of the FPC-emitted function:
#
#   1  the link map contributes a non-empty `.text` section for
#      mormot.core.interfaces' CallMethod, from mormot.core.interfaces.o
#   2  it contributes the matching non-empty `.pdata` and `.xdata`, and the
#      `$unwind$...CALLMETHOD...` symbol sits at the start of that `.xdata`
#   3  the final PE carries EXACTLY ONE RUNTIME_FUNCTION over that exact
#      code range
#   4  its unwind info RVA is nonzero and lands INSIDE the mapped `.xdata`
#   5  the unwind codes are the ones the prologue actually executes:
#      frame register RBP, SET_FPREG rbp offset 0, PUSH_NONVOL rbp,
#      PUSH_NONVOL r12
#
# and one refusal the OBJ era could not express: no `x64callmethod` symbol
# may appear anywhere in the map. That name only ever came from the removed
# patch, so a tree that grew it back fails here rather than passing quietly
# with two implementations of the same stub.
#
# Requires the executable to be linked with -Xm. dumpbin comes from MSVC,
# which the Windows leg already needs for the webview DLL build.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# the FPC section/symbol names for mormot.core.interfaces' CallMethod. FPC
# mangles a unit-private routine as <unit>_$$_<name>$<param types>, lower
# case in section names and upper case in symbol names.
$TextSection = '.text.n_mormot.core.interfaces_$$_callmethod$tcallmethodargs'
$PdataSection = '.pdata.n_mormot.core.interfaces_$$_callmethod$tcallmethodargs'
$XdataSection = '.xdata.n_mormot.core.interfaces_$$_callmethod$tcallmethodargs'
$UnwindSymbol = '$unwind$MORMOT.CORE.INTERFACES_$$_CALLMETHOD$TCALLMETHODARGS'
$UnitObject = 'mormot.core.interfaces.o'

function Fail([string]$Message) {
    throw "[CAP-3U binary gate] $Message"
}

function Resolve-InputFile([string]$Path, [string]$Description) {
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (($null -eq $resolved) -or
        -not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
        Fail "$Description not found: $Path"
    }
    return $resolved.Path
}

function Resolve-Dumpbin([string]$ExplicitPath) {
    if ($ExplicitPath) {
        return Resolve-InputFile $ExplicitPath 'dumpbin.exe'
    }
    $command = Get-Command dumpbin.exe -CommandType Application `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    if ($env:VCToolsInstallDir) {
        $candidate = Join-Path $env:VCToolsInstallDir `
            'bin\Hostx64\x64\dumpbin.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} `
        'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $installation = (& $vswhere -latest -products '*' `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath).Trim()
        if ($LASTEXITCODE -eq 0 -and $installation) {
            $tools = Join-Path $installation 'VC\Tools\MSVC'
            $candidate = Get-ChildItem -LiteralPath $tools -Directory |
                Sort-Object Name -Descending |
                ForEach-Object {
                    Join-Path $_.FullName 'bin\Hostx64\x64\dumpbin.exe'
                } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
            if ($candidate) { return $candidate }
        }
    }
    Fail 'dumpbin.exe not found; pass -DumpbinPath or initialize an MSVC x64 environment'
}

function Invoke-Dumpbin([string[]]$Arguments) {
    $output = & $script:Dumpbin @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Fail "dumpbin failed ($($Arguments -join ' ')):`n$output"
    }
    return $output
}

if (-not $IsWindows) { Fail 'binary gate requires Windows' }
if (([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne
        [Runtime.InteropServices.Architecture]::X64) -or
    ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne
        [Runtime.InteropServices.Architecture]::X64)) {
    Fail 'binary gate requires a native Windows x64 process'
}

$executable = Resolve-InputFile $ExecutablePath 'final executable'
$map = Resolve-InputFile $MapPath 'final link map'
$script:Dumpbin = Resolve-Dumpbin $DumpbinPath

# --- 1/2. read the three contributions out of the link map ------------------
# The map is tens of megabytes, so it is read ONCE, line by line, rather than
# regex-scanned as a single string. GNU ld puts a long section name on its own
# line and the address/size/object on the next; a short one shares the line.
# Both shapes are accepted, and the object file is required to be the compiled
# dependency unit rather than whatever else might have contributed a section
# of that name.
$wanted = @{
    $TextSection  = 'text'
    $PdataSection = 'pdata'
    $XdataSection = 'xdata'
}
$found = @{}
$symbolVa = @{}
$sawX64CallMethod = $false
$pending = ''
foreach ($line in [IO.File]::ReadLines($map)) {
    if ($line -cmatch 'x64callmethod') { $sawX64CallMethod = $true }

    if ($pending) {
        # the address/size/object line that belongs to the wrapped name above
        if ($line -cmatch '^\s+0x([0-9a-fA-F]+)\s+0x([0-9a-fA-F]+)\s+(\S.*)$') {
            $key = $wanted[$pending]
            if ($found.ContainsKey($key)) {
                Fail "the link map contributes $pending more than once"
            }
            $found[$key] = [pscustomobject]@{
                Section = $pending
                Va      = [Convert]::ToUInt64($Matches[1], 16)
                Size    = [Convert]::ToUInt64($Matches[2], 16)
                Object  = [IO.Path]::GetFileName($Matches[3].Trim())
            }
        }
        else {
            Fail "the link map entry for $pending carries no address/size line"
        }
        $pending = ''
        continue
    }

    if ($line -cmatch '^\s\S') {
        $trimmed = $line.TrimEnd()
        # wrapped form: the section name alone on its line
        if ($wanted.ContainsKey($trimmed.Trim())) {
            $pending = $trimmed.Trim()
            continue
        }
        # inline form: name, address, size, object on one line
        if ($trimmed -cmatch '^\s(\S+)\s+0x([0-9a-fA-F]+)\s+0x([0-9a-fA-F]+)\s+(\S.*)$') {
            $name = $Matches[1]
            if ($wanted.ContainsKey($name)) {
                $key = $wanted[$name]
                if ($found.ContainsKey($key)) {
                    Fail "the link map contributes $name more than once"
                }
                $found[$key] = [pscustomobject]@{
                    Section = $name
                    Va      = [Convert]::ToUInt64($Matches[2], 16)
                    Size    = [Convert]::ToUInt64($Matches[3], 16)
                    Object  = [IO.Path]::GetFileName($Matches[4].Trim())
                }
            }
        }
        continue
    }

    if ($line -cmatch '^\s+0x([0-9a-fA-F]+)\s+(\S+)\s*$') {
        $name = $Matches[2]
        if ($name -ceq $UnwindSymbol) {
            if ($symbolVa.ContainsKey($name)) {
                Fail "the link map declares $UnwindSymbol more than once"
            }
            $symbolVa[$name] = [Convert]::ToUInt64($Matches[1], 16)
        }
    }
}
if ($pending) { Fail "truncated link map entry for $pending" }

if ($sawX64CallMethod) {
    Fail ('the link map names x64callmethod: the removed CAP-3U patch is back ' +
        'in the dependency, and the upstream stub is no longer what runs')
}
foreach ($key in 'text', 'pdata', 'xdata') {
    if (-not $found.ContainsKey($key)) {
        Fail "the link map has no $key contribution for mormot.core.interfaces CallMethod"
    }
    if ($found[$key].Size -eq 0) {
        Fail "the link map $key contribution for CallMethod is empty"
    }
    if ($found[$key].Object -cne $UnitObject) {
        Fail ("the $key contribution for CallMethod came from " +
            "'$($found[$key].Object)', not from $UnitObject")
    }
}
if (-not $symbolVa.ContainsKey($UnwindSymbol)) {
    Fail "the link map declares no $UnwindSymbol"
}
if ($symbolVa[$UnwindSymbol] -ne $found['xdata'].Va) {
    Fail ("$UnwindSymbol is at 0x$($symbolVa[$UnwindSymbol].ToString('X')) but its " +
        "mapped .xdata starts at 0x$($found['xdata'].Va.ToString('X'))")
}

# --- 3. the final PE ---------------------------------------------------------
$headers = Invoke-Dumpbin @('/headers', $executable)
if ($headers -notmatch '(?im)^\s*8664 machine \(x64\)\s*$') {
    Fail 'final executable machine is not x64 (8664)'
}
$imageBaseMatch = [regex]::Match($headers,
    '(?im)^\s*([0-9A-F]+) image base(?:\s+\([^\r\n]+\))?\s*$')
if (-not $imageBaseMatch.Success) { Fail 'unable to read final PE image base' }
$imageBase = [Convert]::ToUInt64($imageBaseMatch.Groups[1].Value, 16)
foreach ($key in 'text', 'xdata') {
    if ($found[$key].Va -lt $imageBase) {
        Fail "the mapped $key address precedes the PE image base"
    }
}
$startRva = $found['text'].Va - $imageBase
$endRva = $startRva + $found['text'].Size

$unwind = Invoke-Dumpbin @('/unwindinfo', $executable)
$startHex = $startRva.ToString('X8')
# The entry must BEGIN at the mapped code start - that is what identifies it as
# CallMethod's and not a neighbour's. Its end is checked against the section
# rather than required to equal it: FPC pads a `.text` contribution to a 16-byte
# boundary, so the mapped size (0x90 here) is the padded one and the
# RUNTIME_FUNCTION covers the 0x8D bytes the function actually occupies. The
# ml64 object this gate used to read happened to need no padding, which is why
# the previous form could demand equality.
$entryPattern = "(?im)^[ \t]*[0-9A-F]+[ \t]+$startHex[ \t]+([0-9A-F]+)[ \t]+([0-9A-F]+)[ \t\r]*$"
$entries = [regex]::Matches($unwind, $entryPattern)
if ($entries.Count -ne 1) {
    Fail ("expected one RUNTIME_FUNCTION starting at $startHex, found " +
        "$($entries.Count) -- an FPC that ignored the .seh_* directives emits none")
}
$entryEndRva = [Convert]::ToUInt64($entries[0].Groups[1].Value, 16)
if (($entryEndRva -le $startRva) -or ($entryEndRva -gt $endRva)) {
    Fail ("the RUNTIME_FUNCTION at $startHex ends at " +
        "$($entryEndRva.ToString('X8')), outside its mapped code contribution " +
        "$startHex..$($endRva.ToString('X8'))")
}
$unwindRva = [Convert]::ToUInt64($entries[0].Groups[2].Value, 16)
if ($unwindRva -eq 0) { Fail 'CallMethod RUNTIME_FUNCTION has zero unwind info' }
$xdataStartRva = $found['xdata'].Va - $imageBase
$xdataEndRva = $xdataStartRva + $found['xdata'].Size
if (($unwindRva -lt $xdataStartRva) -or ($unwindRva -ge $xdataEndRva)) {
    Fail ("CallMethod unwind info RVA $($unwindRva.ToString('X8')) is outside its " +
        "mapped .xdata $($xdataStartRva.ToString('X8'))..$($xdataEndRva.ToString('X8'))")
}

# --- 4/5. the unwind codes ---------------------------------------------------
$entryStart = $entries[0].Index
$entryLineEnd = $unwind.IndexOf("`n", $entryStart)
if ($entryLineEnd -lt 0) { Fail 'truncated dumpbin RUNTIME_FUNCTION entry' }
$tableEntryRegex = [regex]::new(
    '^[ \t]*[0-9A-F]{8}[ \t]+[0-9A-F]{8}[ \t]+[0-9A-F]{8}[ \t]+[0-9A-F]{8}[ \t\r]*$',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
    [Text.RegularExpressions.RegexOptions]::Multiline)
$nextEntry = $tableEntryRegex.Match($unwind, $entryLineEnd + 1)
if ($nextEntry.Success) {
    $entryText = $unwind.Substring($entryStart, $nextEntry.Index - $entryStart)
}
else {
    $entryText = $unwind.Substring($entryStart)
}
if ($entryText -notmatch '(?im)^\s*Unwind version:\s*[1-9][0-9]*\s*$') {
    Fail 'CallMethod has no nonzero unwind version'
}
if ($entryText -notmatch '(?im)^\s*Frame register:\s*rbp\s*$') {
    Fail 'CallMethod unwind frame register is not RBP'
}
if ($entryText -notmatch '(?im)SET_FPREG, register=rbp(?:, offset=0x0+)?\s*$') {
    Fail 'CallMethod unwind codes do not establish RBP with SET_FPREG'
}
if ($entryText -notmatch '(?im)PUSH_NONVOL, register=rbp\s*$') {
    Fail 'CallMethod unwind codes do not save RBP'
}
if ($entryText -notmatch '(?im)PUSH_NONVOL, register=r12\s*$') {
    Fail 'CallMethod unwind codes do not save R12'
}

Write-Host ("[CAP-3U binary gate] map: $UnitObject contributes .text " +
    "0x$($found['text'].Va.ToString('X')) size 0x$($found['text'].Size.ToString('X')), " +
    ".pdata size 0x$($found['pdata'].Size.ToString('X')), " +
    ".xdata size 0x$($found['xdata'].Size.ToString('X')) at the unwind symbol")
Write-Host '[CAP-3U binary gate] map: no x64callmethod symbol -- the patch is gone'
Write-Host ("[CAP-3U binary gate] PE : one RUNTIME_FUNCTION $startHex..$($entryEndRva.ToString('X8')) " +
    "inside the mapped code $startHex..$($endRva.ToString('X8')), unwind RVA " +
    "$($unwindRva.ToString('X8')) inside mapped .xdata, RBP SET_FPREG, saved RBP/R12")
Write-Host '[CAP-3U binary gate] PASS'
