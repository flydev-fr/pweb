# THE BACKLOG GATE'S NEGATIVE SELF-TEST: nineteen perturbations, each of which
# check_backlog.ps1 must refuse, and each of which is byte-restored afterwards.
#
# A gate that has only ever been seen to PASS has an unproven failure path, and
# this repository has measured that class often enough to have a rule about it.
# The first draft of the gate's `create_help_compared` check is why this file
# exists rather than being a nicety on top: it looked for the two field names
# anywhere in check_cap7f_aggregate.ps1, and BOTH names also appear in that
# file's `$required` list - so it reported `true` for a field deleted from the
# `$equalityFields` list it was supposed to be guarding. Nothing but a leg that
# actually deleted the line could have shown that.
#
# EVERY PERTURBATION IS RESTORED IN A `finally`, byte for byte from a copy
# taken before anything ran, and the last thing this script does is re-run the
# gate on the restored tree and require it to pass - because a self-test that
# leaves the working tree perturbed has traded one silent failure for another.
#
# Checkout-only. Exits nonzero if any leg fails to be refused, or if the tree
# does not come back.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
Set-Location $repoRoot
$gate = Join-Path $PSScriptRoot 'check_backlog.ps1'

# every file a leg touches, saved before any leg runs
$targets = [ordered]@{
    backlog = 'test/backlog/dispositions.tsv'
    doc     = 'docs/backlog.md'
    ga      = 'tools/templates/react/gitattributes'
    abi     = 'test/cap7l/check_abi.sh'
    b1      = 'test/cap10b1/run_cap10b1_gates.ps1'
    agg     = 'test/cap7f/check_cap7f_aggregate.ps1'
    c15sh   = 'test/cap15a/run_cap15a.sh'
    c15ps   = 'test/cap15a/run_cap15a.ps1'
    policy  = 'src/security/pweb.navigation.policy.pas'
    ciwf    = '.github/workflows/ci.yml'
}
$backup = @{}
foreach ($k in $targets.Keys) {
    $p = Join-Path $repoRoot $targets[$k]
    if (-not (Test-Path -LiteralPath $p)) { throw "missing $($targets[$k])" }
    $backup[$k] = [System.IO.File]::ReadAllBytes($p)
}
function Restore {
    foreach ($k in $targets.Keys) {
        [System.IO.File]::WriteAllBytes((Join-Path $repoRoot $targets[$k]), $backup[$k])
    }
}
function RunGate {
    $o = & pwsh -NoProfile -File $gate 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o }
}
$results = New-Object System.Collections.Generic.List[bool]
function Leg([string]$Name, [scriptblock]$Perturb, [string]$MustSay) {
    & $Perturb
    $r = RunGate
    Restore
    $ok = ($r.Code -ne 0) -and ($r.Out -match [regex]::Escape($MustSay))
    if ($ok) { Write-Host "  refused  $Name" }
    else {
        Write-Host "  ACCEPTED $Name -- exit=$($r.Code); expected to be refused with: $MustSay"
        ($r.Out -split "`n") | Where-Object { $_ -match 'VIOLATION' } |
            Select-Object -First 3 | ForEach-Object { Write-Host "           got: $_" }
    }
    $results.Add($ok)
}
function Table { return (Join-Path $repoRoot 'test/backlog/dispositions.tsv') }

try {
    $r = RunGate
    if ($r.Code -ne 0) {
        throw ('the gate does not pass on the unperturbed tree, so no leg below ' +
            'would mean anything; fix that first')
    }
    Write-Host '[backlog] baseline PASS; nineteen perturbations follow'

    # Rewrite one row of the disposition table, addressed by its key, so a leg
    # says what it changes rather than depending on a substring that could
    # match somewhere else in a 338-row file.
    function SetRow([string]$Key, [string[]]$Columns) {
        $p = Table
        $lines = [System.IO.File]::ReadAllLines($p)
        $hit = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if (($lines[$i] -split "`t")[0] -ceq $Key) { $lines[$i] = ($Columns -join "`t"); $hit++ }
        }
        if ($hit -ne 1) { throw "SetRow $Key matched $hit row(s), not 1" }
        [System.IO.File]::WriteAllLines($p, $lines)
    }

    # --- the four bookkeeping failures the gate names separately -------------
    Leg 'a ledger entry reworded under an inherited verdict' {
        SetRow '8B-7' @('8B-7', 'deadbeef', 'FIX_NOW', 'this triage', '0029fc5',
            'the digest moved and the verdict did not')
    } 'LEDGER ENTRY REWORDED: 8B-7'

    Leg 'a ledger entry with no row' {
        $p = Table
        $keep = @([System.IO.File]::ReadAllLines($p) |
            Where-Object { ($_ -split "`t")[0] -cne '9A-3' })
        [System.IO.File]::WriteAllLines($p, $keep)
    } 'LEDGER ORPHAN: 9A-3'

    Leg 'a row for an entry the ledger does not carry' {
        $p = Table
        $lines = @([System.IO.File]::ReadAllLines($p)) +
            @("ZZ-9`t0dafdc5d`tROADMAP`tnobody`t-`ta row the ledger does not carry")
        [System.IO.File]::WriteAllLines($p, $lines)
    } 'STRAY ROW'

    Leg 'a verdict outside the closed set' {
        SetRow '9A-3' @('9A-3', '625ccb8f', 'MAYBE', 'synopse/mORMot2', '-',
            'a verdict from no agreed vocabulary')
    } 'UNKNOWN VERDICT'

    # --- the commit rule, in all three directions ---------------------------
    Leg 'a FIX_NOW naming a commit this repository does not carry' {
        SetRow '8B-7' @('8B-7', '0dafdc5d', 'FIX_NOW', 'this triage', '0000000',
            'a commit id nobody can resolve')
    } 'which this repository does not carry'

    Leg 'a FIX_NOW naming no commit at all' {
        SetRow 'B1-8' @('B1-8', '43618ec6', 'FIX_NOW', 'this triage', '-',
            'a closure that cites nothing')
    } 'names no closing commit'

    Leg 'a row that is not a FIX_NOW claiming a commit' {
        SetRow '7F-3' @('7F-3', 'ea6daed4', 'ROADMAP', 'CAP-12', '0029fc5',
            'deferred work cannot cite a closure')
    } 'only a FIX_NOW closes something'

    Leg 'a verdict with no reason behind it' {
        SetRow '7M0-6' @('7M0-6', 'f6616f8e', 'ROADMAP',
            'the shard that next touches the CAP-7L POSIX scripts', '-', 'later')
    } 'carries a verdict with no reason'

    # --- the human half must carry every open row and its own counts ---------
    Leg 'an open row that fell out of the document' {
        $p = Join-Path $repoRoot 'docs/backlog.md'
        $keep = @([System.IO.File]::ReadAllLines($p) | Where-Object { $_ -notmatch '\|\s*`7M0-6`\s*\|' })
        [System.IO.File]::WriteAllLines($p, $keep)
    } 'does not carry 1 open row'

    # THE COUNT IS READ RATHER THAN TYPED, and that is a correction: this leg
    # carried the literal `| `ROADMAP` | 39 |`, so the first shard to add a
    # roadmap row (CAP-14A, which took it to 40) made the perturbation a
    # no-op and the self-test reported a refusal that never fired. A fixture
    # must be derived from the thing it perturbs - the same lesson
    # `test/cap10c1` learned from a hardcoded `/usr/libexec` path.
    Leg 'a summary that disagrees with its own table' {
        $p = Join-Path $repoRoot 'docs/backlog.md'
        $t = [System.IO.File]::ReadAllText($p)
        if ($t -notmatch '\| `ROADMAP` \| (\d+) \|') {
            throw 'the backlog document states no ROADMAP count to perturb'
        }
        $n = [int]$Matches[1]
        [System.IO.File]::WriteAllText($p,
            $t.Replace("| ``ROADMAP`` | $n |", "| ``ROADMAP`` | $($n - 1) |"))
    } 'does not state the measured ROADMAP count'

    # --- the four FIX_NOW closures, each undone in the tree -----------------
    Leg 'B2-15 undone: the template .gitattributes drops *.cfg' {
        $p = Join-Path $repoRoot 'tools/templates/react/gitattributes'
        $t = [System.IO.File]::ReadAllText($p)
        [System.IO.File]::WriteAllText($p, ($t -replace '(?m)^\*\.cfg\s+text\s+eol=lf\r?\n', ''))
    } 'B2-15 REGRESSED'

    Leg 'B1-8 undone: the lossy Start-Process capture returns' {
        $p = Join-Path $repoRoot 'test/cap10b1/run_cap10b1_gates.ps1'
        $t = [System.IO.File]::ReadAllText($p)
        [System.IO.File]::WriteAllText($p, $t.Replace(
            '    $utf8 = [System.Text.UTF8Encoding]::new($false)',
            ("    `$p = Start-PWebProcess -FilePath `$Exe -RedirectStandardOutput `$so`n" +
             '    $utf8 = [System.Text.UTF8Encoding]::new($false)')))
    } 'B1-8 REGRESSED'

    Leg '7M0-6 undone: a bare recursive delete comes back' {
        $p = Join-Path $repoRoot 'test/cap7l/check_abi.sh'
        $t = [System.IO.File]::ReadAllText($p)
        [System.IO.File]::WriteAllText($p, $t.Replace(
            'pweb_rm_tree "${work}" "${repo_root}/build"',
            ('rm -' + 'rf -- "${work}"')))
    } '7M0-6 REGRESSED'

    Leg 'B1-8 undone: the field leaves the four-target equality list' {
        $p = Join-Path $repoRoot 'test/cap7f/check_cap7f_aggregate.ps1'
        foreach ($eol in "`r`n", "`n") {
            $t = [System.IO.File]::ReadAllText($p)
            [System.IO.File]::WriteAllText($p,
                $t.Replace("    'create_help_digest', 'create_help_bytes'," + $eol, ''))
        }
    } 'no longer in the four-target equality list'

    # --- the five CAP-15A claims section 5b re-measures ----------------------
    # 15A-13 is a closure this shard made in source, and 15A-12's two assertions
    # about the instrument are stated in four documents. A closure nothing can
    # fail on is a document, which is the argument section 5 already makes; the
    # legs below are what make section 5b a gate rather than a second document.
    Leg '15A-13 undone: the kept fixture deletes bare again' {
        $p = Join-Path $repoRoot 'test/cap15a/run_cap15a.sh'
        $t = [System.IO.File]::ReadAllText($p)
        [System.IO.File]::WriteAllText($p, $t.Replace(
            'pweb_rm_tree "${unitdir}" "${repo_root}/build"',
            ('rm -' + 'rf -- "${unitdir}"')))
    } '15A-13 REGRESSED'

    Leg '15A-13 undone: the fixture stops sourcing the delete guard' {
        $p = Join-Path $repoRoot 'test/cap15a/run_cap15a.sh'
        $t = [System.IO.File]::ReadAllText($p)
        [System.IO.File]::WriteAllText($p, $t.Replace(
            '. "${repo_root}/tools/pweb' + 'rmtree.sh"', ':'))
    } '15A-13 REGRESSED'

    Leg '15A-13 undone: the Windows sibling deletes without an allowed root' {
        $p = Join-Path $repoRoot 'test/cap15a/run_cap15a.ps1'
        $t = [System.IO.File]::ReadAllText($p)
        [System.IO.File]::WriteAllText($p,
            $t.Replace('Assert-' + 'UnderBuildRoot', 'Get-FullPathAnywhere'))
    } '15A-13 REGRESSED'

    Leg '15A-12 undone: a workflow names the widened-CSP instrument' {
        $p = Join-Path $repoRoot '.github/workflows/ci.yml'
        $t = [System.IO.File]::ReadAllText($p)
        [System.IO.File]::WriteAllText($p,
            $t + "`n# pwsh test/cap" + "15a/run_cap15a.ps1`n")
    } '15A-12 REGRESSED'

    # The needle is what BOTH runners substitute, so a reformat of the shipped
    # constant turns reopening condition 1's "one run per macOS architecture"
    # into "repair the instrument first" - on a macOS host, after the runner
    # has been paid for. Perturbing the SPACING is the realistic shape: nobody
    # deletes that constant, somebody re-wraps it.
    Leg 'the CAP-15A shim needle no longer matches the shipped CSP' {
        $p = Join-Path $repoRoot 'src/security/pweb.navigation.policy.pas'
        $t = [System.IO.File]::ReadAllText($p)
        [System.IO.File]::WriteAllText($p,
            $t.Replace("'connect-src ''self''; ", "'connect-src  ''self''; "))
    } 'the CAP-15A shim needle occurs'
}
finally { Restore }

$refused = @($results | Where-Object { $_ }).Count
Write-Host ''
Write-Host "[backlog] negative self-test: $refused/$($results.Count) legs refused as required"
$r = RunGate
if ($r.Code -ne 0) {
    Write-Host '[backlog] SELF-TEST FAILED: the working tree was not restored'
    exit 1
}
Write-Host '[backlog] the restored tree passes the gate'
if ($refused -ne $results.Count) {
    Write-Host '[backlog] SELF-TEST FAILED: a perturbation the gate must refuse was accepted'
    exit 1
}
exit 0
