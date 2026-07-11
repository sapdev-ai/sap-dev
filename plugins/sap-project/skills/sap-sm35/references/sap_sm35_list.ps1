# =============================================================================
# sap_sm35_list.ps1  -  batch-input (SM35) session lister + stats triage (/sap-sm35)
#
# Read-only RFC (RFC_READ_TABLE FMODE=R on S4D + EC2, probed 2026-07-11). Lists sessions
# from APQI, joins APQL for log presence, and reports the built-in APQI statistics
# (TRANSCNT total / TRANSCNTE errored transactions / MSGCNTE error messages) -- the
# session-level error signal that needs no TemSe read. Also serves the `process` mode's
# post-run poll (list one session, read its QSTATE). QSTATE is decoded at runtime from the
# APQ_STAT domain (DD07V), raw code always shown.
#
#   -Session <G>  -Status new|error|processed|inprocess|all  -CreatedBy U
#   -FromDate YYYYMMDD -ToDate YYYYMMDD  -Max N  [-Profile <hint>] -OutDir <dir>
#
# stdout: SM35: session name=<g> qid=<q> state=<s>(<label>) created=<d>/<u> trans=<t>
#         errors=<e> msgs=<m> log=<Y|N> prog=<p>   +   SM35: LISTED n=<k>. Exit 0/2.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Session   = '',
    [string] $Status    = 'all',
    [string] $CreatedBy = '',
    [string] $FromDate  = '',
    [string] $ToDate    = '',
    [int]    $Max       = 100,
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

# well-known BDC session QSTATE codes (fallback; runtime DD07V decode wins)
$stateMap = @{ ' '='new'; ''='new'; 'C'='created/new'; 'E'='errors'; 'F'='processed'; 'R'='in process'; 'X'='in background'; 'Y'='being created'; 'A'='ended incorrectly' }
$statusToCodes = @{ 'new'=@('','C',' '); 'error'=@('E'); 'processed'=@('F'); 'inprocess'=@('R','X','Y') }

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $OutDir) { Write-Host 'STATUS: SM35_RFC_UNAVAILABLE no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$d = $null
if ($Profile) {
    $cands = @(Resolve-SapProfileHint -Hint $Profile)
    if ($cands.Count -ne 1) { Write-Host "STATUS: RFC_LOGON_FAILED profile=$Profile"; exit 2 }
    $c = $cands[0]; $pw = (& (Join-Path $scripts 'sap_dpapi.ps1') -Action unprotect -Value "$($c.password_dpapi)" 2>$null) -as [string]
    try { $d = Connect-SapRfc -Server $c.application_server -Sysnr $c.system_number -MessageServer $c.message_server -LogonGroup $c.logon_group -SystemID $c.system_id -Client $c.client -User $c.user -Password $pw -Language $c.language -DestName ("SM35_"+$c.system_name) } catch { }
} else { try { $d = Connect-SapRfc -DestName 'SM35' } catch { } }
if (-not $d) { Write-Host 'STATUS: SM35_RFC_UNAVAILABLE (run /sap-doctor)'; exit 2 }

try {
    # runtime QSTATE decode from DD07V
    try { $dv = @(Read-Rows $d 'DD07V' "DOMNAME = 'APQ_STAT' AND DDLANGUAGE = 'E'" @('DOMVALUE_L','DDTEXT') 30); foreach ($r in $dv) { $k=San $r.DOMVALUE_L; if ($k) { $stateMap[$k]=San $r.DDTEXT } } } catch { }

    $w = @()
    if ($Session)   { $w += "GROUPID = '$($Session.ToUpper())'" }
    if ($CreatedBy) { $w += "CREATOR = '$($CreatedBy.ToUpper())'" }
    if ($FromDate)  { $w += "CREDATE GE '$FromDate'" }
    if ($ToDate)    { $w += "CREDATE LE '$ToDate'" }
    if ($Status -and $Status.ToLower() -ne 'all' -and $statusToCodes.ContainsKey($Status.ToLower())) {
        $codes = $statusToCodes[$Status.ToLower()]
        if ($codes.Count -eq 1 -and $codes[0]) { $w += "QSTATE = '$($codes[0])'" }
    }
    $where = ($w -join ' AND ')
    $rows = @(Read-Rows $d 'APQI' $where @('GROUPID','QID','QSTATE','CREATOR','CREDATE','CRETIME','TRANSCNT','TRANSCNTE','MSGCNTE','PROGID','DATATYP') $Max)
    # keep only real BDC data-type queues (DATATYP='BDC')
    $rows = @($rows | Where-Object { (San $_.DATATYP) -eq 'BDC' })
    # client-side status filter for multi-code statuses
    if ($Status -and $Status.ToLower() -in @('new','inprocess')) { $codes=$statusToCodes[$Status.ToLower()]; $rows = @($rows | Where-Object { $codes -contains (San $_.QSTATE) }) }

    $lines = @(); $errSessions=0
    foreach ($r in ($rows | Sort-Object { $_.CREDATE } -Descending)) {
        $g=San $r.GROUPID; $qid=San $r.QID; $st=San $r.QSTATE; $lbl = if ($stateMap.ContainsKey($st)) { $stateMap[$st] } else { "code $st" }
        $te=[int]("0"+(San $r.TRANSCNTE)); if ($st -eq 'E') { $errSessions++ }
        # log presence
        $lg = @(Read-Rows $d 'APQL' "QID = '$qid'" @('TEMSEID') 1)
        $hasLog = if ($lg.Count) { 'Y' } else { 'N' }
        Write-Host ("SM35: session name=$g qid=$qid state=$st($lbl) created=$(San $r.CREDATE)/$(San $r.CREATOR) trans=$(San $r.TRANSCNT) errors=$te msgs=$(San $r.MSGCNTE) log=$hasLog prog=$(San $r.PROGID)")
        $lines += (@($g,$qid,$st,$lbl,(San $r.CREATOR),(San $r.CREDATE),(San $r.CRETIME),(San $r.TRANSCNT),$te,(San $r.MSGCNTE),$hasLog,(San $r.PROGID)) -join "`t")
    }
    $sb = New-Object System.Text.StringBuilder; [void]$sb.AppendLine("groupid`tqid`tqstate`tstate_label`tcreator`tcredate`tcretime`ttrans_total`ttrans_error`tmsg_error`thas_log`tprogid")
    foreach ($l in $lines) { [void]$sb.AppendLine($l) }
    [IO.File]::WriteAllText((Join-Path $OutDir 'sm35_sessions.tsv'), $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
    Write-Host ("SM35: LISTED n=$($rows.Count) error_sessions=$errSessions")
    Write-Host 'STATUS: OK'
    Disconnect-SapRfc; exit 0
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
