# =============================================================================
# sap_replay_compile.ps1  -  compile + lint for /sap-test-replay
#
# Reads a sapdev.replay/1 scenario (JSON) + optional bindings TSV and either:
#   -Action lint     validate offline + RFC: token coverage, guard completeness,
#                    tcode existence (TSTC), table-checkpoint (table,field) vs DDIC
#                    (DDIF_FIELDINFO_GET). RFC missing -> LINT_PARTIAL (never false-clean).
#   -Action compile  split the linear steps at `table` checkpoints into GUI SEGMENTS,
#                    emit one steps TSV per segment + table_checks.tsv (for the RFC
#                    assertion engine). Local only.
#
# LINT: <kind> <OK|ERROR|COULD_NOT_CHECK> detail=<...>   +   VERDICT: LINT_OK|LINT_ERROR|LINT_PARTIAL
# COMPILE: segments=<n> checks=<n>
# Exit: 0 ok, 1 lint error / unbound token (REPLAY_SCENARIO_INVALID), 2 input/connect.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Action = 'lint',
    [string] $Scenario = '',
    [string] $Data = '',
    [string] $OutDir = '',
    [string] $SharedDir = '',
    [string] $RunId = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Scenario=$Scenario; Data=$Data }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }
function Sq { param([string]$s) return (("$s") -replace "'", "''") }

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Scenario -or -not (Test-Path $Scenario)) { Write-Host "STATUS: REPLAY_SCENARIO_INVALID detail=scenario_missing"; exit 2 }
    try { $sc = Get-Content $Scenario -Raw | ConvertFrom-Json } catch { Write-Host "STATUS: REPLAY_SCENARIO_INVALID detail=json_parse"; exit 1 }
    if (-not $sc.steps) { Write-Host "STATUS: REPLAY_SCENARIO_INVALID detail=no_steps"; exit 1 }

    # bindings
    $bind = @{}
    if ($Data -and (Test-Path $Data)) { foreach ($ln in [System.IO.File]::ReadAllLines($Data)) { if($ln -match '^\s*#' -or $ln.Trim() -eq ''){continue}; $c=$ln -split "`t"; if($c.Count -ge 2 -and $c[0].Trim().ToLower() -ne 'token'){ $bind[$c[0].Trim().ToUpper()]=$c[1] } } }

    # collect tokens used + guard/checkpoint issues
    $tokRe = [regex]'%%([A-Z0-9_:]+)%%'
    $usedTokens = New-Object System.Collections.Generic.HashSet[string]
    $captures = New-Object System.Collections.Generic.HashSet[string]
    $errors = 0; $cnc = 0
    $lint = New-Object System.Collections.Generic.List[string]
    function L { param($k,$s,$d) $lint.Add("LINT: $k $s detail=$d"); Write-Host "LINT: $k $s detail=$d"; if($s -eq 'ERROR'){$script:errors++}; if($s -eq 'COULD_NOT_CHECK'){$script:cnc++} }

    $stepNo = 0
    $tableChecks = @()
    foreach ($st in $sc.steps) {
        $stepNo++
        # guard completeness
        if (-not $st.guard -or -not $st.guard.program -or -not $st.guard.dynpro) { L "guard.step$stepNo" 'ERROR' "step $stepNo has no guard program/dynpro (re-record via /sap-gui-probe)" }
        # tokens in action value
        if ($st.action -and $st.action.value) { foreach ($m in $tokRe.Matches("$($st.action.value)")) { $t=$m.Groups[1].Value.ToUpper(); if ($t -notlike 'CAPTURE:*') { [void]$usedTokens.Add($t) } } }
        # checkpoints
        if ($st.checkpoints) { foreach ($cp in $st.checkpoints) {
            if ($cp.capture) { [void]$captures.Add("CAPTURE:$($cp.capture)".ToUpper()) }
            if ($cp.type -eq 'table') { $tableChecks += [pscustomobject]@{ step=$stepNo; table="$($cp.table)"; field="$($cp.field)"; keyfield="$($cp.keyfield)"; expected="$($cp.expected)" } }
        } }
    }

    # token coverage: every used token must be bound OR captured
    foreach ($t in $usedTokens) { if (-not $bind.ContainsKey($t) -and -not $captures.Contains($t)) { L "token.$t" 'ERROR' "token %%$t%% is neither in bindings nor captured" } }
    if ($usedTokens.Count -gt 0 -and $errors -eq 0) { L 'tokens' 'OK' "all $($usedTokens.Count) token(s) bound/captured" }

    # RFC checks (tcode + table fields)
    $g_dest = $null
    if ($Action -eq 'lint') {
        $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -DestName "SAPDEV_REPLAY_LINT"
        if (-not $g_dest) {
            L 'rfc' 'COULD_NOT_CHECK' 'no RFC profile - tcode + DDIC checks skipped (LINT_PARTIAL)'
        } else {
            if ($sc.tcode) { $r=$null; try { $r = Read-SapTableRows -Destination $g_dest -Table 'TSTC' -Where "TCODE EQ '$(Sq $sc.tcode.ToUpper())'" -Fields @('TCODE') -RowCount 1 } catch { $r=$null }
                if ($null -eq $r) { L "tcode.$($sc.tcode)" 'COULD_NOT_CHECK' 'TSTC read failed' } elseif (@($r).Count) { L "tcode.$($sc.tcode)" 'OK' 'exists in TSTC' } else { L "tcode.$($sc.tcode)" 'ERROR' 'transaction not in TSTC' } }
            foreach ($tc in $tableChecks) {
                if (-not $tc.table -or -not $tc.field) { L "table.step$($tc.step)" 'ERROR' 'table checkpoint missing table/field'; continue }
                $ok=$false; $ran=$true
                try { $fn=$g_dest.Repository.CreateFunction('DDIF_FIELDINFO_GET'); $fn.SetValue('TABNAME',$tc.table.ToUpper()); $fn.SetValue('FIELDNAME',$tc.field.ToUpper()); $fn.SetValue('LANGU','E'); $fn.Invoke($g_dest); $df=$fn.GetTable('DFIES_TAB'); $ok=($df.RowCount -gt 0) } catch { $ran=$false }
                if (-not $ran) { L "table.$($tc.table)-$($tc.field)" 'COULD_NOT_CHECK' 'DDIF read failed' }
                elseif ($ok) { L "table.$($tc.table)-$($tc.field)" 'OK' 'field exists' }
                else { L "table.$($tc.table)-$($tc.field)" 'ERROR' "$($tc.field) not in $($tc.table)" }
            }
            try { Disconnect-SapRfc } catch {}
        }
    }

    # compile: split into segments at table checkpoints
    if ($Action -eq 'compile') {
        if (-not $OutDir) { $OutDir = Join-Path (Get-Location).Path 'compiled' }
        if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
        $seg = 0; $rows = New-Object System.Collections.Generic.List[string]
        $rows.Add("step`tid`tverb`tvalue`tguard_program`tguard_dynpro`ttimeout_s")
        function FlushSeg { if ($rows.Count -gt 1) { $script:seg++; $p = Join-Path $OutDir ("segment_{0:D2}.tsv" -f $script:seg); [System.IO.File]::WriteAllText($p, ($rows -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true))); $rows.Clear(); $rows.Add("step`tid`tverb`tvalue`tguard_program`tguard_dynpro`ttimeout_s") } }
        $stepNo=0
        foreach ($st in $sc.steps) {
            $stepNo++
            $val = "$($st.action.value)"; foreach ($k in $bind.Keys) { $val = $val -replace [regex]::Escape("%%$k%%"), $bind[$k] }
            $to = if ($st.guard.timeout_s) { $st.guard.timeout_s } else { 30 }
            $rows.Add("$stepNo`t$($st.action.id)`t$($st.action.verb)`t$val`t$($st.guard.program)`t$($st.guard.dynpro)`t$to")
            if ($st.checkpoints) { if (@($st.checkpoints | Where-Object { $_.type -eq 'table' }).Count) { FlushSeg } }
        }
        FlushSeg
        # table_checks.tsv
        $tc = @("step`ttable`tfield`tkeyfield`texpected") + @($tableChecks | ForEach-Object { "$($_.step)`t$($_.table)`t$($_.field)`t$($_.keyfield)`t$($_.expected)" })
        [System.IO.File]::WriteAllText((Join-Path $OutDir 'table_checks.tsv'), ($tc -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true)))
        Write-Host ("COMPILE: segments=$seg checks=$($tableChecks.Count) outdir=$OutDir")
    }

    $verdict = if ($errors -gt 0) { 'LINT_ERROR' } elseif ($cnc -gt 0) { 'LINT_PARTIAL' } else { 'LINT_OK' }
    Write-Host ("VERDICT: $verdict errors=$errors could_not_check=$cnc")
    Write-Host "STATUS: OK"
    exit ($(if ($errors -gt 0) {1} else {0}))
}
