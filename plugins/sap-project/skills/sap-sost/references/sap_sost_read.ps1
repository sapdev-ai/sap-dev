# =============================================================================
# sap_sost_read.ps1  -  SAPconnect outbound-queue triage backend (/sap-sost)
#
# Read-only RFC (RFC_READ_TABLE FMODE=R on S4D + EC2, probed 2026-07-11). Three actions:
#   list    SOST status-log snapshot filtered by date / transmission method / status
#           (MSGTY: E,A=error  W=wait  S,I=sent); --cluster groups by (MSGID,MSGNO) with
#           the T100 error text -> top root causes.
#   trace   per-message status timeline over SOST (by object id OBJTP/OBJYR/OBJNO), so you
#           see created -> attempt(s) -> final; recipient substring matched best-effort on
#           the MSGV variables. NOT_IN_SAPCONNECT when nothing matches (-> app layer).
#   config  SCOT health: SXNODES active nodes, RSCONN01 send job (TBTCP->TBTCO), stuck-queue
#           age (SOST error/wait in window). Tri-state CheckResults -> verdict.
#
#   -Action list|trace|config  [-Status error|wait|sent|all] [-Type INT|FAX|PAG]
#   [-FromDate YYYYMMDD] [-ToDate YYYYMMDD] [-Sender U] [-Recipient <substr>] [-Cluster]
#   [-StuckHours N] [-Max N]  [-Profile <hint>] -OutDir <dir>
#
# stdout: SOST:/SOSTCLUSTER:/SOSTTRACE:/SOSTCHECK: lines + STATUS: <verdict>. Exit 0/1/2.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Action    = 'list',
    [string] $Status    = 'error',
    [string] $Type      = '',
    [string] $FromDate  = '',
    [string] $ToDate    = '',
    [string] $Sender    = '',
    [string] $Recipient = '',
    [switch] $Cluster,
    [int]    $StuckHours = 4,
    [int]    $Max       = 500,
    [string] $Profile   = '',
    [string] $OutDir    = '',
    [string] $SharedDir = '',
    [string] $RunId     = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
foreach ($lib in 'sap_connection_lib.ps1','sap_rfc_lib.ps1') { $pp = Join-Path $scripts $lib; if (Test-Path $pp) { . $pp } }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Invoke-Rfc { param($fn,$d) try { $fn.Invoke($d); return $true } catch { if ("$($_.Exception.Message)" -match 'TABLE_WITHOUT_DATA') { return $false } else { throw } } }
function Add-Where { param($fn,[string]$where)
    if (-not $where) { return }
    $line=''
    foreach ($cl in ($where -split '\s+AND\s+')) { $piece = if ($line -eq '') { $cl } else { "AND $cl" }; if ($line -eq '') { $line=$piece } elseif (($line.Length+1+$piece.Length) -le 72) { $line="$line $piece" } else { Add-RfcOption $fn $line; $line=$piece } }
    if ($line) { Add-RfcOption $fn $line }
}
function Read-Rows { param($d,[string]$table,[string]$where,[string[]]$fields,[int]$max)
    $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''
    if ($max -gt 0) { [void]$fn.SetValue('ROWCOUNT',$max) }
    if ($where) { Add-Where $fn $where }
    foreach ($f in $fields) { Add-RfcField $fn $f }
    if (-not (Invoke-Rfc $fn $d)) { return @() }
    $fm=$fn.GetTable('FIELDS');$off=@{};$len=@{};for($x=0;$x -lt $fm.RowCount;$x++){$fm.CurrentIndex=$x;$nm=(San $fm.GetString('FIELDNAME'));$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
    $dt=$fn.GetTable('DATA');$out=@();for($x=0;$x -lt $dt.RowCount;$x++){$dt.CurrentIndex=$x;$wa="$($dt.GetString('WA'))";$rec=[ordered]@{};foreach($f in $fields){$o=$off[$f];$l=$len[$f];$rec[$f]=if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).Trim()}else{''}};$out+=,([pscustomobject]$rec)}
    return $out
}
function Msg-Text { param($d,[string]$id,[string]$no) if (-not $id -or -not $no) { return '' }; $r=@(Read-Rows $d 'T100' "SPRSL = 'E' AND ARBGB = '$id' AND MSGNR = '$no'" @('TEXT') 1); if ($r.Count) { return $r[0].TEXT } else { return '' } }
function Status-Codes { param([string]$s) switch ($s.ToLower()) { 'error' { @('E','A') } 'wait' { @('W') } 'sent' { @('S','I') } default { @() } } }

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $OutDir) { Write-Host 'STATUS: RFC_ERROR no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
if (-not $FromDate) { $FromDate = (Get-Date).AddDays(-7).ToString('yyyyMMdd') }

$d = $null
if ($Profile) {
    $cands = @(Resolve-SapProfileHint -Hint $Profile)
    if ($cands.Count -ne 1) { Write-Host "STATUS: RFC_LOGON_FAILED profile=$Profile"; exit 2 }
    $c = $cands[0]; $pw = (& (Join-Path $scripts 'sap_dpapi.ps1') -Action unprotect -Value "$($c.password_dpapi)" 2>$null) -as [string]
    try { $d = Connect-SapRfc -Server $c.application_server -Sysnr $c.system_number -MessageServer $c.message_server -LogonGroup $c.logon_group -SystemID $c.system_id -Client $c.client -User $c.user -Password $pw -Language $c.language -DestName ("SOST_"+$c.system_name) } catch { }
} else { try { $d = Connect-SapRfc -DestName 'SOST' } catch { } }
if (-not $d) { Write-Host 'STATUS: RFC_ERROR rfc_unavailable'; exit 2 }

try {
    # common SOST read (status log)
    function Read-Sost {
        $w = @("STAT_DATE GE '$FromDate'")
        if ($ToDate) { $w += "STAT_DATE LE '$ToDate'" }
        if ($Type)   { $w += "SNDART = '$($Type.ToUpper())'" }
        @(Read-Rows $d 'SOST' ($w -join ' AND ') @('OBJTP','OBJYR','OBJNO','COUNTER','SNDART','STAT_DATE','STAT_TIME','MSGTY','MSGID','MSGNO','MSGV1','MSGV2','SENDER','DIRECTION') $Max)
    }

    if ($Action -eq 'list') {
        $rows = Read-Sost
        $codes = Status-Codes $Status
        if ($codes.Count) { $rows = @($rows | Where-Object { $codes -contains (San $_.MSGTY) }) }
        if ($Sender)    { $rows = @($rows | Where-Object { (San $_.SENDER) -like "*$Sender*" }) }
        if ($Recipient) { $rows = @($rows | Where-Object { "$($_.MSGV1)$($_.MSGV2)" -like "*$Recipient*" }) }
        $lines=@()
        foreach ($r in ($rows | Select-Object -First 100)) {
            Write-Host ("SOST: date=$(San $r.STAT_DATE) time=$(San $r.STAT_TIME) type=$(San $r.SNDART) msgty=$(San $r.MSGTY) msg=$(San $r.MSGID)-$(San $r.MSGNO) node=$(San $r.MSGV1) obj=$(San $r.OBJTP)$(San $r.OBJYR)$(San $r.OBJNO)")
        }
        foreach ($r in $rows) { $lines += (@((San $r.STAT_DATE),(San $r.STAT_TIME),(San $r.SNDART),(San $r.MSGTY),"$(San $r.MSGID)-$(San $r.MSGNO)",(San $r.MSGV1),(San $r.SENDER),"$(San $r.OBJTP)$(San $r.OBJYR)$(San $r.OBJNO)") -join "`t") }
        $sb=New-Object System.Text.StringBuilder;[void]$sb.AppendLine("stat_date`tstat_time`ttype`tmsgty`tmessage`tnode`tsender`tobject");foreach($l in $lines){[void]$sb.AppendLine($l)}
        [IO.File]::WriteAllText((Join-Path $OutDir 'queue_snapshot.tsv'),$sb.ToString(),(New-Object Text.UTF8Encoding($true)))
        if ($Cluster) {
            $grp=@{}
            foreach ($r in $rows) { $k="$(San $r.MSGID)-$(San $r.MSGNO)"; if(-not $grp.ContainsKey($k)){$grp[$k]=@{n=0;ty=(San $r.MSGTY);id=(San $r.MSGID);no=(San $r.MSGNO);last=''}}; $grp[$k].n++; $sd=San $r.STAT_DATE; if($sd -gt $grp[$k].last){$grp[$k].last=$sd} }
            $cl=@()
            foreach ($k in ($grp.Keys | Sort-Object { $grp[$_].n } -Descending)) { $g=$grp[$k]; $txt=Msg-Text $d $g.id $g.no; Write-Host ("SOSTCLUSTER: msg=$k msgty=$($g.ty) count=$($g.n) last=$($g.last) text=`"$txt`""); $cl+=(@($k,$g.ty,$g.n,$g.last,$txt) -join "`t") }
            $sb2=New-Object System.Text.StringBuilder;[void]$sb2.AppendLine("message`tmsgty`tcount`tlast_seen`ttext");foreach($l in $cl){[void]$sb2.AppendLine($l)}
            [IO.File]::WriteAllText((Join-Path $OutDir 'error_clusters.tsv'),$sb2.ToString(),(New-Object Text.UTF8Encoding($true)))
        }
        Write-Host ("STATUS: OK rows=$($rows.Count)")
        Disconnect-SapRfc; exit 0
    }
    elseif ($Action -eq 'trace') {
        $rows = Read-Sost
        if ($Recipient) { $rows = @($rows | Where-Object { "$($_.MSGV1)$($_.MSGV2)$($_.SENDER)" -like "*$Recipient*" }) }
        if ($Sender)    { $rows = @($rows | Where-Object { (San $_.SENDER) -like "*$Sender*" }) }
        if ($rows.Count -eq 0) { Write-Host "SOSTTRACE: NOT_IN_SAPCONNECT (no SOST rows match; check the application output layer /sap-output-diagnose)"; Write-Host 'STATUS: OK rows=0'; Disconnect-SapRfc; exit 0 }
        $byObj = $rows | Group-Object { "$($_.OBJTP)$($_.OBJYR)$($_.OBJNO)" }
        foreach ($grp in ($byObj | Select-Object -First 20)) {
            Write-Host ("SOSTTRACE: object=$($grp.Name) attempts=$($grp.Count)")
            foreach ($r in ($grp.Group | Sort-Object { "$($_.STAT_DATE)$($_.STAT_TIME)" })) { $txt=Msg-Text $d (San $r.MSGID) (San $r.MSGNO); Write-Host ("  $(San $r.STAT_DATE) $(San $r.STAT_TIME) msgty=$(San $r.MSGTY) $(San $r.MSGID)-$(San $r.MSGNO) $txt") }
        }
        Write-Host ("STATUS: OK objects=$($byObj.Count)")
        Disconnect-SapRfc; exit 0
    }
    elseif ($Action -eq 'config') {
        $findings=@()
        # 1. nodes
        $nodes = @(Read-Rows $d 'SXNODES' '' @('NODE','ACTIVE','RFCDEST','DESCRIP') 100)
        $active = @($nodes | Where-Object { (San $_.ACTIVE) -eq 'X' })
        $nodeVerdict = if ($nodes.Count -eq 0) { 'NO_G' } elseif ($active.Count -eq 0) { 'NO_G' } else { 'OK' }
        Write-Host ("SOSTCHECK: nodes total=$($nodes.Count) active=$($active.Count) verdict=$nodeVerdict")
        foreach ($n in $nodes) { Write-Host ("  node=$(San $n.NODE) active=$(San $n.ACTIVE) rfcdest=$(San $n.RFCDEST)") }
        $findings += "nodes`t$($nodes.Count)`t$($active.Count)`t$nodeVerdict"
        # 2. RSCONN01 send job
        $jobs = @(Read-Rows $d 'TBTCP' "PROGNAME = 'RSCONN01'" @('JOBNAME','JOBCOUNT') 20)
        $jobState='NONE'; $jobVerdict='NO_G'
        if ($jobs.Count) {
            $jn = San $jobs[0].JOBNAME; $jc = San $jobs[0].JOBCOUNT
            $tc = @(Read-Rows $d 'TBTCO' "JOBNAME = '$jn'" @('STATUS','SDLSTRTDT') 5)
            if ($tc.Count) { $jobState = San ($tc[0].STATUS); $jobVerdict = if ($jobState -in @('A','F')) { 'WARN' } else { 'OK' } }
        }
        Write-Host ("SOSTCHECK: send_job program=RSCONN01 steps=$($jobs.Count) last_status=$jobState verdict=$jobVerdict")
        $findings += "send_job`t$($jobs.Count)`t$jobState`t$jobVerdict"
        # 3. stuck queue (error/wait in window)
        $sost = Read-Sost
        $stuck = @($sost | Where-Object { (San $_.MSGTY) -in @('E','A','W') })
        $stuckVerdict = if ($stuck.Count -gt 0) { 'WARN' } else { 'OK' }
        Write-Host ("SOSTCHECK: stuck_queue error_wait_rows=$($stuck.Count) since=$FromDate verdict=$stuckVerdict")
        $findings += "stuck_queue`t$($stuck.Count)`t`t$stuckVerdict"
        $sb=New-Object System.Text.StringBuilder;[void]$sb.AppendLine("check`tmetric1`tmetric2`tverdict");foreach($l in $findings){[void]$sb.AppendLine($l)}
        [IO.File]::WriteAllText((Join-Path $OutDir 'config_check.tsv'),$sb.ToString(),(New-Object Text.UTF8Encoding($true)))
        $overall = if ($findings -match 'NO_G') { 'NO_GO' } elseif ($findings -match 'WARN') { 'GO_WITH_WARNINGS' } else { 'GO' }
        Write-Host ("STATUS: OK verdict=$overall")
        Disconnect-SapRfc; exit 0
    }
    else { Write-Host "STATUS: RFC_ERROR bad_action=$Action"; Disconnect-SapRfc; exit 2 }
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
