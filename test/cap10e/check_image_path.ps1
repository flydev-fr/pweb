# CAP-10E E8: the source gate that PINS the one-rule property.
#
# The shard's whole claim is that shipped PWeb code has exactly ONE reader of
# the running image's path, and that the RTL's argv is never that reader
# again. A claim like that survives exactly as long as something measures it:
# the defect it closes was introduced by nobody, in the sense that every one
# of the five sites was written correctly against the API that was there.
#
# Checkout-only: no build, no toolchain. It runs wherever
# test/cap7f/check_divergence.ps1 runs, and it emits
# build/cap10e/image-path-sources.json so the CAP-7F emitters can carry its
# rows to the aggregate.
#
# THE FOUR PROPERTIES, over src/**, tools/**, examples/** and sdk/**, with
# Pascal comments STRIPPED first - this file's own subject appears in a dozen
# comments that explain it, and a gate that counted those would be measuring
# prose:
#
#   1  ParamStr(0) appears NOWHERE. It is the defect's source, and there is
#      no legitimate remaining use of it in shipped code.
#   2  Executable.ProgramFilePath / ExeVersion.ProgramFilePath appear
#      NOWHERE. mORMot fills both from ExpandFileName(ParamStr(0)), so they
#      carry the identical mangling one call further out.
#   3  The KERNEL primitives - GetModuleFileName*, _NSGetExecutablePath and
#      the /proc/self/exe link - appear in exactly ONE file, and that file
#      is src/security/pweb.imagepath.pas. This is what makes "one rule"
#      checkable rather than aspirational: a second copy anywhere, however
#      correct, is a second thing that can drift.
#   4  ParamStr(i) and ParamCount - argv, which is a DIFFERENT question from
#      the image path - appear only in the files ratified below, each with
#      its reason. The list is exact in both directions: a file that stops
#      reading argv must leave it, so the reasons cannot rot into fiction.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot
New-Item -ItemType Directory -Force build/cap10e | Out-Null

$violations = New-Object System.Collections.Generic.List[string]
$report = New-Object System.Collections.Generic.List[string]

# THE one file allowed to ask the kernel where this process's image is
$HELPER = 'src/security/pweb.imagepath.pas'

# argv readers, ratified per file with the reason each one is not the image
# path. Anything else reading argv in shipped code is a new decision and
# fails here until it is ratified in the same commit.
$ARGV_READERS = [ordered]@{
    'src/webview/pweb.webview.host.pas' =
        'the two ratified host arguments (verdict file, autoclose) - values, never a trusted location'
    'src/webview/pweb.webview.devhost.pas' =
        'the CAP-10C2 dev-host arguments, same shape'
    'examples/08-release/releaseapp.pas' =
        'the acceptance host''s two optional arguments'
    'examples/07-quickjs/quickjsapp.pas' =
        'the acceptance host''s two optional arguments'
    'examples/04-react/reactapp.pas' =
        'a Phase 5 DEMO that takes its asset folder on the command line; it resolves nothing beside its executable, ships in no SDK, and is run only by a gate that passes it an ASCII path'
    'examples/05-pas2js/pas2jsapp.pas' =
        'the Pas2JS twin of the same demo, same shape and same reason'
    'examples/06-assets/assetsapp.pas' =
        'the CAP-4 asset demo: a mode word and a folder-or-zip path on the command line'
    'examples/06-assets/mkappzip.pas' =
        'the CAP-4 demo''s own zip builder, superseded as a product tool by tools/bundler and kept as the example it always was'
    'tools/bundler/pwebbundle.pas' =
        'ledger D2-13: the POSIX half of its kernel-argv reader, where argv is bytes the RTL hands over unchanged'
    'tools/pweb/pweb.cli.platform.pas' =
        'PWebCliRawArgs, the POSIX half of the CLI''s own kernel-argv seam (ledger D2-12)'
    'tools/pweb/pwebsdk.pas' =
        'the private SDK packager''s own command line; a build tool, never shipped'
    'tools/pweb/pwebtemplates.pas' =
        'the private template-pack builder''s own command line; a build tool, never shipped'
    'tools/quickjs/pwebqjspack.pas' =
        'LEDGERED AND NOT THIS SHARD''S: the bundler''s twin still reads its two paths through the RTL argv. It does not ship in the SDK, no pweb command spawns it, and closing it is CAP-9C1 surface with a supersession of its own'
}

function Strip-Comments([string]$Text) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    $n = $Text.Length
    $inBrace = $false
    $inParen = $false
    $inLine = $false
    $inStr = $false
    while ($i -lt $n) {
        $c = $Text[$i]
        $d = if ($i + 1 -lt $n) { $Text[$i + 1] } else { [char]0 }
        if ($inLine) {
            if ($c -eq "`n") { $inLine = $false; [void]$sb.Append($c) }
            $i++; continue
        }
        if ($inBrace) {
            if ($c -eq '}') { $inBrace = $false }
            elseif ($c -eq "`n") { [void]$sb.Append($c) }
            $i++; continue
        }
        if ($inParen) {
            if (($c -eq '*') -and ($d -eq ')')) { $inParen = $false; $i += 2; continue }
            if ($c -eq "`n") { [void]$sb.Append($c) }
            $i++; continue
        }
        if ($inStr) {
            [void]$sb.Append($c)
            if ($c -eq "'") { $inStr = $false }
            $i++; continue
        }
        if ($c -eq "'") { $inStr = $true; [void]$sb.Append($c); $i++; continue }
        if ($c -eq '{') { $inBrace = $true; $i++; continue }
        if (($c -eq '(') -and ($d -eq '*')) { $inParen = $true; $i += 2; continue }
        if (($c -eq '/') -and ($d -eq '/')) { $inLine = $true; $i += 2; continue }
        [void]$sb.Append($c)
        $i++
    }
    return $sb.ToString()
}

function Get-RelPath([string]$FullName) {
    return ($FullName.Substring($repoRoot.Length).TrimStart('\', '/')) -replace '\\', '/'
}

# the shipped Pascal surface. tools/ is swept whole rather than by named
# subdirectory: a new build tool that starts reading argv is exactly the
# drift this gate exists to catch, and it should have to say so here.
$roots = @('src', 'tools', 'examples', 'sdk')
$files = foreach ($root in $roots) {
    if (Test-Path $root) {
        Get-ChildItem $root -Recurse -File -Include '*.pas', '*.pp', '*.inc', '*.lpr' |
            Where-Object { $_.FullName -notmatch '[\\/](node_modules|dist)[\\/]' }
    }
}

$paramStr0 = @()
$programFilePath = @()
$kernelPrimitives = @{}
$argvSeen = @{}
$helperImpl = @()

# the needles are built by concatenation so this gate cannot be satisfied by
# a scan of itself, the CAP-10D1/10D2 discipline applied to a new sweep
$rxParamStr0 = [regex]::new('ParamStr' + '\(\s*0\s*\)')
$rxParamStrN = [regex]::new('ParamStr' + '\(|Param' + 'Count')
$rxProgramFilePath = [regex]::new('Program' + 'FilePath')
$rxKernel = [regex]::new('GetModule' + 'FileName|_NSGet' + 'ExecutablePath|/proc/self/exe')
$rxHelperImpl = [regex]::new('function\s+PWebImage(File|Dir)\b')

foreach ($file in $files) {
    $rel = Get-RelPath $file.FullName
    $code = Strip-Comments ([System.IO.File]::ReadAllText($file.FullName))
    $lineNo = 0
    foreach ($line in ($code -split "`n")) {
        $lineNo++
        if ($rxParamStr0.IsMatch($line)) {
            $paramStr0 += "${rel}:${lineNo}"
            $report.Add("PARAMSTR0 ${rel}:${lineNo}")
        }
        if ($rxProgramFilePath.IsMatch($line)) {
            $programFilePath += "${rel}:${lineNo}"
            $report.Add("PROGRAMFILEPATH ${rel}:${lineNo}")
        }
        if ($rxKernel.IsMatch($line)) {
            if (-not $kernelPrimitives.ContainsKey($rel)) { $kernelPrimitives[$rel] = 0 }
            $kernelPrimitives[$rel]++
        }
        if ($rxParamStrN.IsMatch($line)) {
            if (-not $argvSeen.ContainsKey($rel)) { $argvSeen[$rel] = 0 }
            $argvSeen[$rel]++
        }
        if ($rxHelperImpl.IsMatch($line)) { $helperImpl += $rel }
    }
}

# --- 1. ParamStr(0) is gone --------------------------------------------------
foreach ($hit in $paramStr0) {
    $violations.Add("ParamStr(0) in shipped code: $hit -- the image path comes from $HELPER")
}

# --- 2. ProgramFilePath is gone ---------------------------------------------
foreach ($hit in $programFilePath) {
    $violations.Add(("ProgramFilePath in shipped code: $hit -- mORMot fills it from " +
        "ExpandFileName(ParamStr(0)) and it carries the identical mangling"))
}

# --- 3. the kernel primitives live in exactly one file ----------------------
if (-not (Test-Path $HELPER)) {
    $violations.Add("the helper is missing: $HELPER")
} elseif (-not $kernelPrimitives.ContainsKey($HELPER)) {
    $violations.Add(("$HELPER asks the kernel nothing -- the rule it owns has " +
        'been emptied out'))
}
foreach ($rel in ($kernelPrimitives.Keys | Sort-Object)) {
    if ($rel -cne $HELPER) {
        $violations.Add(("a SECOND reader of the running image: $rel " +
            "($($kernelPrimitives[$rel]) site(s)) -- one rule, and it lives in $HELPER"))
    }
}

# --- 4. the argv readers are exactly the ratified set -----------------------
foreach ($rel in ($argvSeen.Keys | Sort-Object)) {
    if (-not $ARGV_READERS.Contains($rel)) {
        $violations.Add(("an unratified argv reader: $rel ($($argvSeen[$rel]) site(s)) " +
            '-- argv is not the image path; ratify it here in the same commit ' +
            'if it is genuinely reading arguments'))
    }
}
foreach ($rel in $ARGV_READERS.Keys) {
    if (-not (Test-Path $rel)) {
        $violations.Add("a ratified argv reader is missing: $rel")
    } elseif (-not $argvSeen.ContainsKey($rel)) {
        $violations.Add(("$rel no longer reads argv -- remove its row rather than " +
            'leaving a reason nobody can check'))
    }
}

# --- 5. one implementation of the rule --------------------------------------
$helperFiles = @($helperImpl | Sort-Object -Unique)
if ($helperFiles.Count -ne 1) {
    $violations.Add(("PWebImageFile/PWebImageDir are declared in " +
        "$($helperFiles.Count) file(s) [$($helperFiles -join ', ')]; exactly one is the rule"))
} elseif ($helperFiles[0] -cne $HELPER) {
    $violations.Add("the rule moved out of $HELPER into $($helperFiles[0])")
}

# --- report + verdict --------------------------------------------------------
$facts = [ordered]@{
    schema                   = 1
    surface                  = ($roots -join ',')
    files_scanned            = @($files).Count
    paramstr0_path_sites     = @($paramStr0).Count
    programfilepath_sites    = @($programFilePath).Count
    image_reader_files       = (($kernelPrimitives.Keys | Sort-Object) -join ',')
    image_reader_count       = @($kernelPrimitives.Keys).Count
    argv_reader_files        = (($argvSeen.Keys | Sort-Object) -join ',')
    argv_readers_ratified    = @($ARGV_READERS.Keys).Count
    helper_unit              = $HELPER
    violations               = $violations.Count
    verdict                  = if ($violations.Count -eq 0) { 'PASS' } else { 'FAIL' }
}
[System.IO.File]::WriteAllText(
    (Join-Path (Resolve-Path build/cap10e).Path 'image-path-sources.json'),
    (($facts | ConvertTo-Json -Depth 4) + "`n"), [System.Text.UTF8Encoding]::new($false))
foreach ($r in $report) { Write-Host $r }
Write-Host ($facts | ConvertTo-Json -Depth 4)

if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Write-Host "VIOLATION: $v" }
    throw "CAP-10E image-path source gate FAILED: $($violations.Count) violation(s)"
}
Write-Host ("[CAP-10E] image-path source gate PASS - $(@($files).Count) file(s), " +
    "0 ParamStr(0), 0 ProgramFilePath, one reader ($HELPER)")
