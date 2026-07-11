# =============================================================================
# sap_cutover_verify.ps1  -  read-only RFC verifier for one cutover step
#
# Verifies a single step's post-condition over RFC (no writes). Connects the step's target
# system profile (the /sap-login second-profile pattern) or the pinned connection when -System
# is blank. A failed / unreachable verify is COULD_NOT_CHECK and NEVER auto-marks a step done.
#
#   TRANSPORT_IMPORT  TPALOG max RETCODE for TRKORR (<=4 PASS, >=8 FAIL); TRBAT row => RUNNING;
#                     no log + not running => COULD_NOT_CHECK (not yet imported / cannot confirm).
#   JOB_SCHEDULE      TBTCO latest STATUS by jobname: F=PASS, A=FAIL, R/Y/P/S=RUNNING, none=CNC.
#   REPORT_RUN        same as job when a jobname is given; foreground runs => COULD_NOT_CHECK
#                     (attach evidence with --evidence).
#   TABLE_CHECK       RFC_READ_TABLE row count on <table> [<where>] -> PASS with count in detail.
#
#   -StepType <t> [-System <hint>] [-Trkorr <tr>] [-Target <sid>] [-Jobname <j>] [-Table <t>] [-Where <w>]
#   [-SharedDir <dir>] [-RunId <id>]
#
# stdout: VERIFY: <PASS|FAIL|RUNNING|COULD_NOT_CHECK> detail="<..>" + STATUS: OK|RFC_LOGON_FAILED|RFC_ERROR
# exit 0 (ran, incl. COULD_NOT_CHECK) / 2 (connect/input)
# =============================================================================
[CmdletBinding()]
param(
    [ValidateSet('TRANSPORT_IMPORT','JOB_SCHEDULE','REPORT_RUN','TABLE_CHECK')]
    [string] $StepType = 'TABLE_CHECK',
    [string] $System   = '',
    [string] $Trkorr   = '',
    [string] $Target   = '',
    [string] $Jobname  = '',
    [string] $Table    = '',
    [string] $Where    = '',
    [string] $SharedDir= '',
    [string] $RunId    = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
foreach ($lib in 'sap_connection_lib.ps1','sap_rfc_lib.ps1') { $pp = Join-Path $scripts $lib; if (Test-Path $pp) { . $pp } }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Invoke-Rfc { param($fn,$d) try { $fn.Invoke($d); return $true } catch { $m="$($_.Exception.Message)"; if ($m -match 'TABLE_WITHOUT_DATA' -or $m -match 'FIELD_NOT_VALID') { return $false } else { throw } } }
function Read-Rows { param($d,[string]$table,[string]$where,[string[]]$fields,[int]$max)
    $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''; if ($max -gt 0) { [void]$fn.SetValue('ROWCOUNT',$max) }
    if ($where) { $line=''; foreach ($cl in ($where -split '\s+AND\s+')) { $piece = if ($line -eq '') { $cl } else { "AND $cl" }; if ($line -eq '') { $line=$piece } elseif (($line.Length+1+$piece.Length) -le 72) { $line="$line $piece" } else { Add-RfcOption $fn $line; $line=$piece } }; if ($line) { Add-RfcOption $fn $line } }
    foreach ($f in $fields) { Add-RfcField $fn $f }
    if (-not (Invoke-Rfc $fn $d)) { return @() }
    $fm=$fn.GetTable('FIELDS');$off=@{};$len=@{};for($x=0;$x -lt $fm.RowCount;$x++){$fm.CurrentIndex=$x;$nm=("$($fm.GetString('FIELDNAME'))").Trim();$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
    $dt=$fn.GetTable('DATA');$out=@();for($x=0;$x -lt $dt.RowCount;$x++){$dt.CurrentIndex=$x;$wa="$($dt.GetString('WA'))";$rec=[ordered]@{};foreach($f in $fields){$o=$off[$f];$l=$len[$f];$rec[$f]=if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).Trim()}else{''}};$out+=,([pscustomobject]$rec)}
    return $out
}
function Count-Rows { param($d,[string]$table,[string]$where)
    $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''; [void]$fn.SetValue('ROWCOUNT',0)
    if ($where) { $line=''; foreach ($cl in ($where -split '\s+AND\s+')) { $piece = if ($line -eq '') { $cl } else { "AND $cl" }; if ($line -eq '') { $line=$piece } elseif (($line.Length+1+$piece.Length) -le 72) { $line="$line $piece" } else { Add-RfcOption $fn $line; $line=$piece } }; if ($line) { Add-RfcOption $fn $line } }
    # request one narrow field (first key) so a wide table does not blow the buffer
    $fi = $d.Repository.CreateFunction('DDIF_FIELDINFO_GET'); $fi.SetValue('TABNAME',$table); $fi.SetValue('LANGU','E'); $fi.Invoke($d)
    $df=$fi.GetTable('DFIES_TAB'); $df.CurrentIndex=0; $key=("$($df.GetString('FIELDNAME'))").Trim()
    Add-RfcField $fn $key
    if (-not (Invoke-Rfc $fn $d)) { return 0 }
    return $fn.GetTable('DATA').RowCount
}

function Emit { param($v,$detail) Write-Host ("VERIFY: {0} detail=`"{1}`"" -f $v,((San $detail) -replace '"',"'")); Write-Host 'STATUS: OK'; try { Disconnect-SapRfc } catch {}; exit 0 }

# ---- connect target profile (or pinned) ----
$dest = $null
try {
    if ($System) {
        $cands = @(Resolve-SapProfileHint -Hint $System)
        if ($cands.Count -ne 1) { Write-Host ("VERIFY: COULD_NOT_CHECK detail=`"target profile '{0}' resolves to {1} candidates`"" -f $System,$cands.Count); Write-Host 'STATUS: OK'; exit 0 }
        $t = $cands[0]
        $pw = (& (Join-Path $scripts 'sap_dpapi.ps1') -Action unprotect -Value "$($t.password_dpapi)" 2>$null) -as [string]
        $dest = Connect-SapRfc -Server $t.application_server -Sysnr $t.system_number -MessageServer $t.message_server -LogonGroup $t.logon_group -SystemID $t.system_id -Client $t.client -User $t.user -Password $pw -Language $t.language -DestName 'CUT_VERIFY'
    } else {
        $dest = Connect-SapRfc -DestName 'CUT_VERIFY'
    }
} catch { }
if (-not $dest) { Write-Host 'VERIFY: COULD_NOT_CHECK detail="target system unreachable"'; Write-Host 'STATUS: RFC_LOGON_FAILED'; exit 2 }

try {
    switch ($StepType) {
        'TRANSPORT_IMPORT' {
            if (-not $Trkorr) { Emit 'COULD_NOT_CHECK' 'no TRKORR to verify' }
            $tr = $Trkorr.ToUpper()
            $running = 0; try { $running = @(Read-Rows $dest 'TRBAT' "TRKORR = '$tr'" @('TRKORR','FUNCTION','RETCODE') 20).Count } catch { }
            $log = @(Read-Rows $dest 'TPALOG' "TRKORR = '$tr'" @('TRKORR','TRSTEP','RETCODE','TARSYSTEM') 200)
            if ($Target) { $log = @($log | Where-Object { -not $_.TARSYSTEM -or $_.TARSYSTEM -eq $Target -or $_.TARSYSTEM -eq 'ALL' }) }
            if ($log.Count -eq 0) {
                if ($running -gt 0) { Emit 'RUNNING' "import in progress (TRBAT has $tr), no TPALOG result yet" }
                Emit 'COULD_NOT_CHECK' "no TPALOG import log for $tr on target - not yet imported or log unavailable"
            }
            $maxRc = (($log | ForEach-Object { [int]("0"+($_.RETCODE))} ) | Measure-Object -Maximum).Maximum
            if ($running -gt 0) { Emit 'RUNNING' "import still running (TRBAT), last logged maxRC=$maxRc" }
            if ($maxRc -ge 8) { Emit 'FAIL' "TPALOG max return code $maxRc for $tr (>=8 = error)" }
            Emit 'PASS' "TPALOG max return code $maxRc for $tr (<=4 = OK), steps=$($log.Count)"
        }
        { $_ -eq 'JOB_SCHEDULE' -or $_ -eq 'REPORT_RUN' } {
            if (-not $Jobname) {
                if ($StepType -eq 'REPORT_RUN') { Emit 'COULD_NOT_CHECK' 'foreground report run - attach spool evidence with --evidence' }
                Emit 'COULD_NOT_CHECK' 'no jobname to verify'
            }
            $jobs = @(Read-Rows $dest 'TBTCO' "JOBNAME = '$Jobname'" @('JOBNAME','STATUS','SDLSTRTDT','SDLSTRTTM') 200)
            if ($jobs.Count -eq 0) { Emit 'COULD_NOT_CHECK' "no TBTCO entry for job $Jobname" }
            $latest = @($jobs | Sort-Object { "$($_.SDLSTRTDT)$($_.SDLSTRTTM)" } -Descending)[0]
            $s = (San $latest.STATUS)
            switch ($s) {
                'F' { Emit 'PASS'    "job $Jobname finished (TBTCO status F), scheduled $($latest.SDLSTRTDT)" }
                'A' { Emit 'FAIL'    "job $Jobname aborted (TBTCO status A), scheduled $($latest.SDLSTRTDT)" }
                default { Emit 'RUNNING' "job $Jobname status=$s (R/Y/P/S = ready/scheduled/running), scheduled $($latest.SDLSTRTDT)" }
            }
        }
        'TABLE_CHECK' {
            if (-not $Table) { Emit 'COULD_NOT_CHECK' 'no table to check' }
            $n = Count-Rows $dest $Table.ToUpper() $Where
            Emit 'PASS' "table $Table row count = $n$(if($Where){" where [$Where]"}else{''})"
        }
    }
} catch {
    Write-Host ("VERIFY: COULD_NOT_CHECK detail=`"{0}`"" -f ((San $_.Exception.Message) -replace '"',"'")); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch {}; exit 0
}
