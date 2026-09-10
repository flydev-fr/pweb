# CAP-15B: the native outbound network door, gated.
#
# The door CAP-15A ratified: `pweb.fetch` behind the `network.fetch`
# capability and a native, per-application origin allowlist compiled into
# the host, with `PWEB_NATIVE_CSP` unchanged - `connect-src` still `'self'`,
# byte for byte, on all four targets.
#
#   S1   the headless suite: every row of §4 and §5 through the INJECTED
#        transport, with the transport ENTRY COUNT asserted on each refusal
#   L1   the SHIPPED transport against a real local server, whose JSONL
#        request log is the independent witness
#   D1   macOS only: the §10 NSURLSession measurement
#   P1   the schema-2 descriptor reader: a schema-1 project reads as [] and
#        gains no door, an empty set is a set, a malformed origin refuses AT
#        LOAD, a loopback origin is accepted by the descriptor
#   B1   PWEB_NATIVE_CSP is byte-identical in the built network host and in
#        the shipped source constant
#   B2   the compiled allowlist digest EQUALS the one computed from
#        pweb.json - declared == compiled, at the bytes of the image
#   B3   the release image carries no relaxation, AND THE SWEEP IS PROVEN
#        DISCRIMINATING: the same sweep is run against a DEV image that
#        carries the loopback origin by design and is REQUIRED TO FIRE.
#        A negative check whose firing was never observed is the vacuous
#        gate class this repository has caught three times already
#   B4   `mormot.net.client` is on the network host's compiled unit set and
#        ABSENT from the no-origins host's - "the door is not in its image"
#   B5   app.pwb: the bundler refuses a network/origins/connect/csp field
#
# Emits build/cap15b/cli-<target>.json for the CAP-7F aggregation.
#
# Usage: pwsh test/cap15b/run_cap15b_gates.ps1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot

$exeSuffix = if ($IsWindows) { '.exe' } else { '' }
$work = Join-Path $repoRoot 'build/cap15b'
New-Item -ItemType Directory -Force $work | Out-Null

$rows = [ordered]@{}
$failures = New-Object System.Collections.Generic.List[string]
function Row([string]$Key, [string]$Value) { $rows[$Key] = $Value }
function Require([bool]$Ok, [string]$Message) {
    if (-not $Ok) {
        $failures.Add($Message)
        Write-Host "GATE FAILURE: $Message"
    }
}
function Bool([bool]$B) { if ($B) { 'true' } else { 'false' } }
function TargetName {
    $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64'   { 'x86_64' }
        'Arm64' { 'arm64' }
        default { 'other' }
    }
    return "$os-$arch"
}
function Sha256Text([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString(
            $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        ).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}
# every printable ASCII run of 4+ bytes in a binary - the same reading a
# `strings` would give, without needing one on four platforms
function ImageStrings([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sb = New-Object System.Text.StringBuilder
    $out = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) {
        if ($b -ge 0x20 -and $b -lt 0x7f) { [void]$sb.Append([char]$b) }
        else {
            if ($sb.Length -ge 4) { [void]$out.AppendLine($sb.ToString()) }
            [void]$sb.Clear()
        }
    }
    if ($sb.Length -ge 4) { [void]$out.AppendLine($sb.ToString()) }
    return $out.ToString()
}

$target = TargetName
Row 'target' $target
$bin = Join-Path $work 'bin'

# --- S1: the headless suite -------------------------------------------------
$suite = Join-Path $bin "cap15btests$exeSuffix"
Require (Test-Path $suite) 'the CAP-15B suite is not built - run build_cap15b first'
if (Test-Path $suite) {
    Remove-Item -Force (Join-Path $work 'fetch-corpus.txt') -ErrorAction SilentlyContinue
    # /noenter is the WINDOWS switch that skips mormot.core.test's
    # interactive pause; on POSIX the suite never waits
    if ($IsWindows) { $out = & $suite /noenter 2>&1 | Out-String }
    else { $out = & $suite 2>&1 | Out-String }
    $suiteOk = ($LASTEXITCODE -eq 0)
    Row 'fetch_suite' $(if ($suiteOk) { 'PASS' } else { 'FAIL' })
    Require $suiteOk 'S1: the CAP-15B headless suite failed'
    if (-not $suiteOk) { Write-Host $out }
    $corpus = Join-Path $work 'fetch-corpus.txt'
    if (Test-Path $corpus) {
        # LF-normalised before hashing, so the four targets compare the
        # DECISIONS rather than their line endings
        $text = [System.IO.File]::ReadAllText($corpus).Replace("`r`n", "`n")
        Row 'fetch_corpus_digest' (Sha256Text $text)
        Row 'fetch_corpus_lines' ([string](($text -split "`n").Count - 1))
    } else {
        Row 'fetch_corpus_digest' ''
        Require $false 'S1: the suite wrote no decision corpus'
    }
}

# --- L1: the shipped transport, against a real local server ----------------
$live = Join-Path $bin "fetchlive$exeSuffix"
Require (Test-Path $live) 'the CAP-15B live driver is not built'
$port = 17300 + (Get-Random -Maximum 400)
$wire = Join-Path $work "wire-$target.jsonl"
$liveOut = Join-Path $work "live-$target.json"
Remove-Item -Force $wire, $liveOut -ErrorAction SilentlyContinue
$node = (Get-Command node -ErrorAction SilentlyContinue)
Require ($null -ne $node) 'node is required for the CAP-15B local witness'
if ((Test-Path $live) -and ($null -ne $node)) {
    # --ttl is the backstop; --stdin-shutdown is not used here because this
    # runner owns the process and stops it by handle
    # -WindowStyle is a WINDOWS-only parameter of Start-Process and this
    # runner is the same file on four targets, so it is simply not used
    $srv = Start-Process -FilePath $node.Source -PassThru `
        -ArgumentList @('test/cap15b/probe_server.js', "--port=$port",
            '--ttl=300', "--log=$wire")
    try {
        $ready = $false
        for ($i = 0; $i -lt 100; $i++) {
            try {
                Invoke-WebRequest -Uri "http://127.0.0.1:$port/ready" `
                    -TimeoutSec 2 -UseBasicParsing | Out-Null
                $ready = $true
                break
            } catch { Start-Sleep -Milliseconds 200 }
        }
        Require $ready 'L1: the local witness never accepted a connection'
        if ($ready) {
            # the public TLS row is RECORDED and never gates: a real
            # certificate chain cannot come from a local server, because TLS
            # validation is not disableable anywhere in this product
            & $live "--port=$port" "--log=$wire" "--out=$liveOut" `
                '--public-tls=https://example.com/' 2>&1 | Write-Host
            $liveOk = ($LASTEXITCODE -eq 0)
            Require $liveOk 'L1: the live transport rows failed'
            if (Test-Path $liveOut) {
                $j = Get-Content -Raw $liveOut | ConvertFrom-Json
                foreach ($p in $j.PSObject.Properties) { Row $p.Name $p.Value }
            }
        }
    } finally {
        if ($srv -and -not $srv.HasExited) {
            Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- D1: macOS only - the §10 NSURLSession measurement ---------------------
if ($IsMacOS) {
    $probe = Join-Path $bin "darwinprobe$exeSuffix"
    Require (Test-Path $probe) 'the CAP-15B Darwin probe is not built'
    if ((Test-Path $probe) -and ($null -ne $node)) {
        $dport = 17800 + (Get-Random -Maximum 300)
        $dwire = Join-Path $work "wire-darwin-$target.jsonl"
        $dout = Join-Path $work "darwin-$target.json"
        $srv = Start-Process -FilePath $node.Source -PassThru `
            -ArgumentList @('test/cap15b/probe_server.js', "--port=$dport",
                '--ttl=300', "--log=$dwire")
        try {
            for ($i = 0; $i -lt 100; $i++) {
                try {
                    Invoke-WebRequest -Uri "http://127.0.0.1:$dport/ready" `
                        -TimeoutSec 2 -UseBasicParsing | Out-Null
                    break
                } catch { Start-Sleep -Milliseconds 200 }
            }
            & $probe "--port=$dport" "--out=$dout" `
                '--public-tls=https://example.com/' 2>&1 | Write-Host
            Require ($LASTEXITCODE -eq 0) 'D1: the Darwin §10 rows failed'
            if (Test-Path $dout) {
                $j = Get-Content -Raw $dout | ConvertFrom-Json
                foreach ($p in $j.PSObject.Properties) { Row $p.Name $p.Value }
            }
            # THE MACHINE'S OWN PROXY CONFIGURATION, recorded beside the row
            # it qualifies (rider 3): the probe can only say that the
            # configuration it built carried an empty proxy dictionary
            $scutil = ''
            try { $scutil = (& scutil --proxy 2>&1 | Out-String) } catch { }
            $hasProxy = ($scutil -match 'Enable\s*:\s*1')
            Row 'darwin_runner_proxy_configured' (Bool $hasProxy)
        } finally {
            if ($srv -and -not $srv.HasExited) {
                Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
} else {
    Row 'darwin_probe' 'not_applicable'
}

# --- P1/B1-B4: the descriptor, and two REAL compiled hosts ------------------
. (Join-Path $repoRoot 'test/cap15b/hostproofs.ps1')
Invoke-Cap15bHostProofs -RepoRoot $repoRoot -Work $work `
    -Rows $rows -Failures $failures

# --- B5: the bundler refuses a network field in app.pwb --------------------
$bundler = Join-Path $bin "pwebbundle$exeSuffix"
Require (Test-Path $bundler) 'the CAP-6 bundler is not built'
if (Test-Path $bundler) {
    $dist = Join-Path $work 'bundle-dist'
    Remove-Item -Recurse -Force $dist -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force (Join-Path $dist 'data') | Out-Null
    Set-Content -NoNewline -Path (Join-Path $dist 'index.html') `
        -Value "<!doctype html><html><head><title>t</title></head><body></body></html>`n"
    # NESTED application data with the same key name is NOT a manifest and
    # must survive: a refusal that swept every JSON in the tree would forbid
    # an application's own data for having a field name
    Set-Content -NoNewline -Path (Join-Path $dist 'data/config.json') `
        -Value "{`"connect`":`"application data, not a manifest`"}`n"
    $clean = Join-Path $work 'clean.pwb'
    Remove-Item -Force $clean -ErrorAction SilentlyContinue
    & $bundler $dist $clean 2>&1 | Out-Null
    $cleanOk = ($LASTEXITCODE -eq 0)
    Row 'bundler_nested_field_accepted' (Bool $cleanOk)
    Require $cleanOk 'B5: the bundler refused nested application data'
    foreach ($field in 'network', 'origins', 'connect', 'csp') {
        Set-Content -NoNewline -Path (Join-Path $dist 'app.json') `
            -Value "{`"name`":`"x`",`"$field`":[`"https://evil.example`"]}`n"
        $outPwb = Join-Path $work "refused-$field.pwb"
        Remove-Item -Force $outPwb -ErrorAction SilentlyContinue
        $bundlerOut = (& $bundler $dist $outPwb 2>&1 | Out-String)
        $refused = ($LASTEXITCODE -ne 0) -and
            ($bundlerOut -match 'network_field_in_bundle')
        Row "bundler_refuses_$field" (Bool $refused)
        Require $refused "B5: the bundler accepted a `$field` field in app.pwb"
        Require (-not (Test-Path $outPwb)) "B5: a refused bundle was written for $field"
        Remove-Item -Force (Join-Path $dist 'app.json') -ErrorAction SilentlyContinue
    }
}

# --- C1: the composition, mechanised once on the Linux leg -----------------
#
# `test/cap15b/prove_cap15b_composition.sh` is the one gate that runs the
# thing a user does on day one - create, declare an origin, build, run, and
# call it from the page through @pweb/runtime. It is Linux-only ON PURPOSE:
# breadth is already where it belongs (the request contract, the grammar, the
# image proofs and the transport all run on four targets), and a fifth copy
# of the composition would buy nothing but four npm installs.
#
# The other three targets emit `not_applicable`, which is a VALUE. A target
# that silently stopped emitting the row would otherwise go unnoticed, which
# is the CAP-10D2 lesson the aggregator's required set is built on.
$compFile = Join-Path $work 'composition-linux-x86_64.json'
if ($IsLinux -and (Test-Path $compFile)) {
    $comp = Get-Content -Raw $compFile | ConvertFrom-Json
    foreach ($p in $comp.PSObject.Properties) { Row $p.Name $p.Value }
    Require ("$($comp.composition)" -ceq 'PASS') 'C1: the composition smoke failed'
} elseif ($IsLinux) {
    Row 'composition' 'FAIL'
    Require $false ('C1: the composition smoke left no record - ' +
        'test/cap15b/prove_cap15b_composition.sh runs before this gate on Linux')
} else {
    foreach ($k in 'composition', 'composition_region', 'composition_fetch',
                   'composition_payload', 'composition_rpc_ok') {
        Row $k 'not_applicable'
    }
    foreach ($k in 'composition_rpc_result', 'composition_listener_members') {
        Row $k '0'
    }
}

# --- verdict ----------------------------------------------------------------
Row 'cap15b_failures' ([string]$failures.Count)
$json = Join-Path $work "cli-$target.json"
($rows | ConvertTo-Json -Depth 4) | Set-Content -NoNewline -Path $json `
    -Encoding utf8
Write-Host "[CAP-15B] evidence: $json"
if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Host "VIOLATION: $f" }
    throw "CAP-15B gates FAILED: $($failures.Count) failure(s)"
}
Write-Host '[CAP-15B] gates PASS - the native fetch door, its bounds, its ' +
    'allowlist and its absence from a project that declared none'
