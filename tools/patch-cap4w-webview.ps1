param(
    [switch]$Restore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$LockFile = Join-Path $RepoRoot 'webview.lock'
$WebViewRoot = Join-Path $RepoRoot 'deps\webview'
$PatchFile = Join-Path $PSScriptRoot 'cap4w\webview2-custom-scheme.patch'
$Targets = @(
    'core/include/webview/detail/backends/win32_edge.hh',
    'core/include/webview/detail/platform/windows/webview2/loader.hh'
)

function Fail([string]$Message) {
    throw "[CAP-4W] $Message"
}

function Read-LockFile {
    $result = @{}
    $lineNumber = 0
    foreach ($lineValue in Get-Content -LiteralPath $LockFile) {
        $lineNumber++
        $line = $lineValue.Trim()
        if (($line -eq '') -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '=') {
            Fail "webview.lock line ${lineNumber} is malformed"
        }
        $key, $value = $line -split '=', 2
        $key = $key.Trim()
        if ($result.ContainsKey($key)) {
            Fail "webview.lock contains duplicate key '$key'"
        }
        $result[$key] = $value.Trim()
    }
    return $result
}

function Normalize-Newlines([string]$Text) {
    return (($Text -replace "`r`n", "`n") -replace "`r", "`n").TrimEnd()
}

function Invoke-GitCapture([string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    [void]$start.ArgumentList.Add('-C')
    [void]$start.ArgumentList.Add($WebViewRoot)
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        Fail "git $($Arguments -join ' ') failed: $stderr"
    }
    return $stdout
}

function Get-DependencyStatus {
    $raw = Invoke-GitCapture @('status', '--porcelain=v1',
        '--untracked-files=all')
    return @($raw -split "`n" | Where-Object { $_ -ne '' })
}

function Get-TargetDiff {
    $arguments = @('diff', '--no-ext-diff', '--no-color', '--') + $Targets
    return Normalize-Newlines (Invoke-GitCapture $arguments)
}

function Assert-PristineShape([string]$PinnedCommit) {
    $backend = Invoke-GitCapture @('show',
        "${PinnedCommit}:$($Targets[0])")
    $loader = Invoke-GitCapture @('show',
        "${PinnedCommit}:$($Targets[1])")
    $backendNeedle = @'
    m_com_handler->set_attempt_handler([&] {
      return m_webview2_loader.create_environment_with_options(
          nullptr, userDataFolder, nullptr, m_com_handler);
    });
'@
    if (-not (Normalize-Newlines $backend).Contains(
            (Normalize-Newlines $backendNeedle))) {
        Fail 'pinned Windows environment-creation source shape is unknown'
    }
    if (-not (Normalize-Newlines $loader).Contains(
            'static constexpr unsigned int api_version = 1150;')) {
        Fail 'pinned WebView2 loader source shape is unknown'
    }
}

function Get-State([string]$ExpectedPatch) {
    $status = @(Get-DependencyStatus)
    if ($status.Count -eq 0) { return 'pristine' }
    $expectedStatus = @(
        ' M core/include/webview/detail/backends/win32_edge.hh',
        ' M core/include/webview/detail/platform/windows/webview2/loader.hh'
    )
    if (($status.Count -ne $expectedStatus.Count) -or
        (@(Compare-Object -ReferenceObject ($status | Sort-Object) `
            -DifferenceObject ($expectedStatus | Sort-Object)).Count -ne 0)) {
        Fail "dependency has unknown changes: $($status -join '; ')"
    }
    if ((Get-TargetDiff) -cne $ExpectedPatch) {
        Fail 'dependency target diff is not the exact CAP-4W patch'
    }
    return 'patched'
}

if (-not $IsWindows) { Fail 'preparation requires Windows' }
foreach ($required in @($LockFile, $PatchFile,
        (Join-Path $WebViewRoot '.git'))) {
    if (-not (Test-Path -LiteralPath $required)) {
        Fail "required path missing: $required"
    }
}

$lock = Read-LockFile
$PinnedCommit = $lock['commit']
$SdkVersion = $lock['webview2-sdk']
$ExpectedPatchHash = $lock['cap4w-patch-sha256']
if (-not $PinnedCommit -or
    ($PinnedCommit -cnotmatch '^[0-9a-f]{40}$')) {
    Fail 'webview.lock has no full lowercase upstream commit'
}
if ($SdkVersion -cne '1.0.1587.40') {
    Fail "unexpected WebView2 SDK pin '$SdkVersion'"
}
if (-not $ExpectedPatchHash -or
    ($ExpectedPatchHash -cnotmatch '^[0-9a-f]{64}$')) {
    Fail 'webview.lock has no full lowercase CAP-4W patch hash'
}
$actualPatchHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $PatchFile).
    Hash.ToLowerInvariant()
if ($actualPatchHash -cne $ExpectedPatchHash) {
    Fail "patch hash mismatch: got $actualPatchHash expected $ExpectedPatchHash"
}

$head = (Invoke-GitCapture @('rev-parse', 'HEAD')).Trim()
if ($head -cne $PinnedCommit) {
    Fail "webview HEAD '$head' does not match '$PinnedCommit'"
}
Assert-PristineShape $PinnedCommit
$expectedPatch = Normalize-Newlines ([IO.File]::ReadAllText($PatchFile))
$dependencyLockPath = Join-Path $WebViewRoot '.git\pweb-cap4w.lock'
try {
    $dependencyLock = [IO.File]::Open($dependencyLockPath,
        [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None)
}
catch {
    Fail 'another CAP-4W patch/restore operation owns the dependency lock'
}

try {
    $state = Get-State $expectedPatch

    if ($Restore) {
        if ($state -eq 'patched') {
            Invoke-GitCapture (@('checkout', '--force', $PinnedCommit, '--') +
                $Targets) | Out-Null
        }
        if ((Get-State $expectedPatch) -ne 'pristine') {
            Fail 'restore did not reproduce the pinned source'
        }
        Write-Host '[CAP-4W] RESTORED pinned webview source'
        return
    }

    if ($state -eq 'patched') {
        Write-Host '[CAP-4W] READY (exact patch already installed)'
        return
    }

    try {
        Invoke-GitCapture @('apply', '--check', '--whitespace=error-all',
            $PatchFile) | Out-Null
        Invoke-GitCapture @('apply', '--whitespace=error-all', $PatchFile) |
            Out-Null
        if ((Get-State $expectedPatch) -ne 'patched') {
            Fail 'installed dependency diff failed exact verification'
        }
    }
    catch {
        $failure = $_
        try {
            Invoke-GitCapture (@('checkout', '--force', $PinnedCommit, '--') +
                $Targets) | Out-Null
        }
        catch {
            Write-Error '[CAP-4W] rollback to pinned git objects failed'
        }
        throw $failure
    }

    Write-Host "[CAP-4W] upstream : $PinnedCommit"
    Write-Host "[CAP-4W] SDK      : $SdkVersion"
    Write-Host "[CAP-4W] patch    : $actualPatchHash"
    Write-Host '[CAP-4W] READY'
}
finally {
    $dependencyLock.Dispose()
}
