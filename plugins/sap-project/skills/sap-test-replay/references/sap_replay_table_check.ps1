# =============================================================================
# sap_replay_table_check.ps1  -  RFC table-checkpoint assertion for /sap-test-replay
#
# Read-only RFC_READ_TABLE assertions at segment boundaries (probed FMODE=R both
# releases). For each row in table_checks.tsv resolve tokens (bindings + captured),
# read the target table keyed by <keyfield>=<value>, assert row-exists (+ field=
# expected when a non-key expected differs). Bounded retry absorbs update-task latency.
#
# CHECK: step=<n> table=<t> result=<PASS|FAIL|COULD_NOT_CHECK> detail=<...>
# Exit: 0 ran, 2 connect/input.
# =============================================================================

[CmdletBinding()]
param(
    [string] $CheckFile = '',
    [string] $Values = '',
    [int]    $Retry = 3,
    [int]    $RetryWaitMs = 2000,
    [string] $OutFile = '',
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
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; CheckFile=$CheckFile; Values=$Values }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }
function Sq { param([string]$s) return (("$s") -replace "'", "''") }

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $CheckFile -or -not (Test-Path $CheckFile)) { Write-Host "STATUS: INPUT_ERROR reason=checkfile"; exit 2 }
    $vals = @{}
    foreach ($pair in @($Values -split ',' | Where-Object { $_ -match '=' })) { $k,$v = $pair -split '=',2; $vals[$k.Trim().ToUpper()]=$v }
    function Sub { param([string]$s) $o=$s; foreach($k in $vals.Keys){ $o = $o -replace [regex]::Escape("%%$k%%"), $vals[$k]; $o = $o -replace [regex]::Escape("%%CAPTURE:$k%%"), $vals[$k] }; return $o }

    $lines = [System.IO.File]::ReadAllLines($CheckFile)
    $checks = @(); for ($i=1;$i -lt $lines.Count;$i++){ if($lines[$i].Trim() -eq ''){continue}; $c=$lines[$i] -split "`t"; if($c.Count -ge 4){ $checks += [pscustomobject]@{ step=$c[0]; table=$c[1]; field=$c[2]; keyfield=$c[3]; expected=$(if($c.Count -ge 5){$c[4]}else{''}) } } }
    if ($checks.Count -eq 0) { Write-Host "STATUS: OK"; Write-Host "INFO: no table checks"; exit 0 }

    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -DestName "SAPDEV_REPLAY_CHECK"
    if (-not $g_dest) { foreach ($c in $checks) { Write-Host "CHECK: step=$($c.step) table=$($c.table) result=COULD_NOT_CHECK detail=no_rfc" }; Write-Host "STATUS: OK"; exit 0 }

    $out = New-Object System.Collections.Generic.List[string]; $out.Add("step`ttable`tfield`texpected`tactual`tresult")
    foreach ($c in $checks) {
        $keyval = Sub $c.keyfield; if ($keyval -eq $c.keyfield) { $keyval = Sub $c.expected }
        $expected = Sub $c.expected
        $result='FAIL'; $actual=''; $ran=$false; $maxTry=[Math]::Max(1,$Retry)
        for ($try=0; $try -lt $maxTry; $try++) {
            $r = $null
            try { $r = Read-SapTableRows -Destination $g_dest -Table $c.table.ToUpper() -Where "$($c.keyfield.ToUpper()) EQ '$(Sq $keyval)'" -Fields @($c.field.ToUpper()) -RowCount 1; $ran=$true } catch { $ran=$false; break }
            if ($null -eq $r) { $ran=$false; break }
            if (@($r).Count -gt 0) { $actual = "$($r[0].($c.field.ToUpper()))"; $result = $(if (-not $expected -or $expected -eq $keyval -or "$actual" -eq "$expected") { 'PASS' } else { 'FAIL' }); break }
            else { $result='FAIL'; $actual='(no row)'; if ($try -lt ($maxTry-1)) { Start-Sleep -Milliseconds $RetryWaitMs } }
        }
        if (-not $ran) { $result='COULD_NOT_CHECK'; $actual='(read failed)' }
        Write-Host "CHECK: step=$($c.step) table=$($c.table) result=$result detail=key=$keyval field=$($c.field) expected='$expected' actual='$actual'"
        $out.Add("$($c.step)`t$($c.table)`t$($c.field)`t$expected`t$actual`t$result")
    }
    if ($OutFile) { [System.IO.File]::WriteAllText($OutFile, ($out -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true))) }
    Write-Host "STATUS: OK"
    try { Disconnect-SapRfc } catch {}
    exit 0
}
