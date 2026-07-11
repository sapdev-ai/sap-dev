# =============================================================================
# sap_replay_report.ps1  -  verdict roll-up for /sap-test-replay (offline)
#
# Parses the interpreter's REPLAY:/MSG: lines + the table-check CHECK: lines and
# rolls up per-step and scenario verdicts, keeping FAIL (regression) STRICTLY
# distinct from REPLAY_ERROR (the replay broke) so flakiness never masquerades as
# a regression. Emits results.tsv, report.md, and one sapdev.testverdict/1 line.
#
#   Scenario verdict: REPLAY_ERROR > FAIL > PASS_WITH_GAPS (any COULD_NOT_CHECK) > PASS.
# Line grammar:
#   REPLAY: step=<n> result=<PASS|FAIL|REPLAY_ERROR> [reason=..] detail=..
#   CHECK:  step=<n> table=<t> result=<PASS|FAIL|COULD_NOT_CHECK> detail=..
#   MSG:    step=<n> result=<PASS|FAIL> detail=..
# Exit: 0 (PASS/PASS_WITH_GAPS), 1 (FAIL), 2 (REPLAY_ERROR).
# =============================================================================

[CmdletBinding()]
param(
    [string] $ReplayFile = '',
    [string] $CheckFile = '',
    [string] $CaseId = 'CASE',
    [string] $ScenarioName = '',
    [string] $EvidencePath = '',
    [string] $OutDir = '',
    [string] $RunId = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = (Get-Location).Path }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$rows = New-Object System.Collections.Generic.List[object]
function Parse-Lines { param([string]$f)
    if (-not $f -or -not (Test-Path $f)) { return }
    foreach ($ln in [System.IO.File]::ReadAllLines($f)) {
        if ($ln -match '^(REPLAY|CHECK|MSG):\s*(.*)$') {
            $kind=$matches[1]; $rest=$matches[2]
            $h=@{}; foreach ($m in [regex]::Matches($rest, "(\w+)=('[^']*'|\S+)")) { $h[$m.Groups[1].Value]=$m.Groups[2].Value.Trim("'") }
            $rows.Add([pscustomobject]@{ kind=$kind; step=$h['step']; result=$h['result']; reason=$h['reason']; table=$h['table']; detail=$rest })
        }
    }
}
Parse-Lines $ReplayFile; Parse-Lines $CheckFile

$replayError = @($rows | Where-Object { $_.result -eq 'REPLAY_ERROR' }).Count
$fails       = @($rows | Where-Object { $_.result -eq 'FAIL' }).Count
$cnc         = @($rows | Where-Object { $_.result -eq 'COULD_NOT_CHECK' }).Count
$passes      = @($rows | Where-Object { $_.result -eq 'PASS' }).Count

$verdict = if ($replayError -gt 0) { 'REPLAY_ERROR' } elseif ($fails -gt 0) { 'FAIL' } elseif ($cnc -gt 0) { 'PASS_WITH_GAPS' } else { 'PASS' }

$tsv = @("kind`tstep`tresult`treason`tdetail") + @($rows | ForEach-Object { "$($_.kind)`t$($_.step)`t$($_.result)`t$($_.reason)`t$(("$($_.detail)") -replace "[`t`r`n]",' ')" })
[System.IO.File]::WriteAllText((Join-Path $OutDir 'results.tsv'), ($tsv -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true)))

$vl = "sapdev.testverdict/1`t$CaseId`tsap-test-replay`t$verdict`t$EvidencePath`t$RunId"
[System.IO.File]::WriteAllText((Join-Path $OutDir 'verdict.tsv'), $vl+"`r`n", (New-Object System.Text.UTF8Encoding($true)))

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Test Replay: $ScenarioName ($CaseId)"); $md.Add("")
$md.Add("**Verdict: $verdict** (pass=$passes fail=$fails replay_error=$replayError could_not_check=$cnc)"); $md.Add("")
$md.Add("| Kind | Step | Result | Reason | Detail |"); $md.Add("|---|---|---|---|---|")
foreach ($r in $rows) { $md.Add("| $($r.kind) | $($r.step) | $($r.result) | $($r.reason) | $(("$($r.detail)") -replace '\|','\\|') |") }
if ($replayError -gt 0) { $md.Add(""); $md.Add("> REPLAY_ERROR means the replay could not finish (guard/popup/capture) - NOT a confirmed regression. Re-record via /sap-gui-probe + /sap-test-replay init if the screens moved.") }
[System.IO.File]::WriteAllText((Join-Path $OutDir 'report.md'), ($md -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($false)))

Write-Host "REPORT: $(Join-Path $OutDir 'report.md')"
Write-Host "VERDICT_LINE: $vl"
Write-Host ("VERDICT: $verdict pass=$passes fail=$fails replay_error=$replayError could_not_check=$cnc")
Write-Host "STATUS: OK"
exit $(if ($verdict -eq 'REPLAY_ERROR') {2} elseif ($verdict -eq 'FAIL') {1} else {0})
