# CAP-10D0: the ONE pwsh argument-quoting helper, for every CAP-10 gate.
#
# THE DEFECT THIS CLOSES (deferred-work C0-12 (b), inherited by CAP-10D):
# `Start-Process -ArgumentList @('run', '--project', $p)` joins the array
# with single spaces and adds NO quoting of its own. So the moment $p carries
# a space - a repository under `C:\pweb work`, a project directory a user
# named `my app` - the child receives four arguments where the gate meant
# three, `--project` takes the first half of the path, and the failure looks
# like a CLI defect rather than a harness one. No hosted runner has a space
# in its workspace today, which is exactly why this survived four shards: it
# is invisible until it is catastrophic.
#
# THE RULE IS NOT INVENTED HERE. It is the C runtime's argument-parsing
# rules in reverse, the same ones PWebCliWindowsCommandLine implements in
# tools/pweb/pweb.cli.platform.pas and the CAP-10C0 golden table proves on
# four targets:
#
#   - an argument is quoted when it is EMPTY or carries a space, a tab, a
#     line feed, a vertical tab or a quote;
#   - N backslashes immediately before a quote become 2N+1 backslashes and
#     an escaped quote;
#   - N backslashes at the END of a quoted argument become 2N;
#   - every other backslash is literal.
#
# One rule, two languages, and the second one is here rather than scattered
# across nine gates - which is the whole of what the ledger entry asked for.
#
# IT APPLIES ON EVERY PLATFORM, not only on Windows: on POSIX .NET hands
# ProcessStartInfo.Arguments to its own splitter, which implements these
# same rules before building argv. A helper that quoted only on Windows
# would leave the POSIX legs measuring a different harness.
#
# Dot-source it, and call Start-PWebProcess instead of Start-Process:
#
#   . (Join-Path $repoRoot 'test/cap10d0/psargs.ps1')
#   $p = Start-PWebProcess -FilePath $pweb -ArgumentList @('build') `
#       -Wait -PassThru -NoNewWindow -WorkingDirectory $cwd `
#       -RedirectStandardOutput $so -RedirectStandardError $se
#
# Start-PWebProcess exists rather than only the joiner because of the empty
# case: `Start-Process -ArgumentList ''` is an error, and a gate that runs a
# tool with NO arguments must not have to remember that. The wrapper omits
# the parameter instead, which is the one thing a call site would otherwise
# get wrong on the day it passes an empty array.

# NO Set-StrictMode here, deliberately: this file is DOT-SOURCED into nine
# gates written before it, and a strict mode set here would apply to all of
# their scopes for the rest of their run. A helper that changes the language
# its callers are written in is a helper that breaks them.

function ConvertTo-PWebArg {
    <#
    .SYNOPSIS
    One argument, quoted for the C runtime's parser if it needs to be.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )
    # the exact five characters the engine quotes on, and no others: a
    # helper that quoted more would still be correct for the child but would
    # stop matching the golden table this rule is proven against
    $special = [char[]]@(' ', "`t", "`n", [char]0x0B, '"')
    if (($Value.Length -gt 0) -and ($Value.IndexOfAny($special) -lt 0)) {
        return $Value
    }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq [char]'\') {
            # counted, never emitted yet: what a run of backslashes means
            # depends entirely on what follows it
            $slashes++
            continue
        }
        if ($ch -eq [char]'"') {
            [void]$sb.Append([char]'\', $slashes * 2 + 1)
            [void]$sb.Append([char]'"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) {
            [void]$sb.Append([char]'\', $slashes)
            $slashes = 0
        }
        [void]$sb.Append($ch)
    }
    # a run that reaches the closing quote is doubled, so the quote stays a
    # delimiter instead of becoming an escaped literal
    if ($slashes -gt 0) {
        [void]$sb.Append([char]'\', $slashes * 2)
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-PWebArgLine {
    <#
    .SYNOPSIS
    An argument vector, as the one command-line string Start-Process needs.
    #>
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )
    if (($null -eq $Arguments) -or ($Arguments.Count -eq 0)) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Arguments) {
        # a $null element is an argument nobody meant to pass; it becomes the
        # empty argument rather than vanishing, so a vector's LENGTH is never
        # changed by this helper
        $parts.Add((ConvertTo-PWebArg ([string]$a)))
    }
    return ($parts -join ' ')
}

function Start-PWebProcess {
    <#
    .SYNOPSIS
    Start-Process with the argument vector quoted by the ratified rule.
    .DESCRIPTION
    Forwards exactly the parameters the CAP-10 gates use and changes no
    other behaviour: the redirection files are still held for the child's
    lifetime on Windows, -PassThru still returns the process, and -Wait
    still waits.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowNull()][AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [string]$RedirectStandardOutput,
        [string]$RedirectStandardError,
        [switch]$Wait,
        [switch]$PassThru,
        [switch]$NoNewWindow
    )
    $splat = @{ FilePath = $FilePath }
    $line = ConvertTo-PWebArgLine $ArgumentList
    # THE EMPTY CASE: Start-Process refuses an empty -ArgumentList, so the
    # parameter is omitted rather than passed empty
    if ($line -ne '') { $splat['ArgumentList'] = $line }
    if ($PSBoundParameters.ContainsKey('WorkingDirectory')) {
        $splat['WorkingDirectory'] = $WorkingDirectory
    }
    if ($PSBoundParameters.ContainsKey('RedirectStandardOutput')) {
        $splat['RedirectStandardOutput'] = $RedirectStandardOutput
    }
    if ($PSBoundParameters.ContainsKey('RedirectStandardError')) {
        $splat['RedirectStandardError'] = $RedirectStandardError
    }
    if ($Wait) { $splat['Wait'] = $true }
    if ($PassThru) { $splat['PassThru'] = $true }
    if ($NoNewWindow) { $splat['NoNewWindow'] = $true }
    return Start-Process @splat
}
