# =============================================================================
# sap_cutover_health.ps1  -  read-only cutover health snapshot for /sap-cutover-runbook
#
# Eight read-only signals per system profile (all FMODE=R / TRANSP, identical S4D + ERP):
#   dumps       SNAP  (SEQNO='000', key fields only; LRAW payload never selected) since start
#   updates     VBHDR row count (pending update records)
#   qrfc_in     TRFCQIN row count       qrfc_out  TRFCQOUT row count
#   trfc        ARFCSSTATE row count (pending/failed tRFC LUWs)
#   batch_input APQI row count (batch-input sessions)
#   locks       ENQUE_READ -> ENQ row count (direct FM, FMODE=R)
#   imports     TRBAT row count (transport imports running)
# Thresholds from cutover_health_defaults.json (override {custom_url}\cutover_health.json).
# Each probe is tri-state: an unreachable probe is COULD_NOT_CHECK, never a silent healthy.
#
#   [-System <hint>] [-StartDate YYYYMMDD] [-Defaults <json>] [-SharedDir <dir>] -OutDir <dir> [-RunId <id>]
# stdout: HEALTH: probe=<p> count=<n> severity=<HIGH|MEDIUM|LOW|INFO> coverage=<CHECKED|COULD_NOT_CHECK> label="<..>"
#         STATUS: OK sid=<SID> | RFC_LOGON_FAILED | RFC_ERROR  ; writes health_<stamp>.tsv ; exit 0/2
# =============================================================================
[CmdletBinding()]
param(
    [string] $System    = '',
    [string] $StartDate = '',
    [string] $Defaults  = '',
    [string] $SharedDir = '',
    [string] $OutDir    = '',
    [string] $RunId     = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
foreach ($lib in 'sap_connection_lib.ps1','sap_rfc_lib.ps1') { $pp = Join-Path $scripts $lib; if (Test-Path $pp) { . $pp } }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Invoke-Rfc { param($fn,$d) try { $fn.Invoke($d); return $true } catch { $m="$($_.Exception.Message)"; if ($m -match 'TABLE_WITHOUT_DATA' -or $m -match 'FIELD_NOT_VALID') { return $false } else { throw } } }
function Count-Rows { param($d,[string]$table,[string]$field,[string]$where)
    $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''; [void]$fn.SetValue('ROWCOUNT',0)
    if ($where) { $line=''; foreach ($cl in ($where -split '\s+AND\s+')) { $piece = if ($line -eq '') { $cl } else { "AND $cl" }; if ($line -eq '') { $line=$piece } elseif (($line.Length+1+$piece.Length) -le 72) { $line="$line $piece" } else { Add-RfcOption $fn $line; $line=$piece } }; if ($line) { Add-RfcOption $fn $line } }
    Add-RfcField $fn $field
    if (-not (Invoke-Rfc $fn $d)) { return 0 }
    return $fn.GetTable('DATA').RowCount
}

# default thresholds (mirrors cutover_health_defaults.json; file override wins)
$TH = @{
    dumps       = @{ warn=1;  crit=20;  label='ABAP short dumps since cutover start (SNAP)' }
    updates     = @{ warn=50; crit=500; label='pending update records (VBHDR)' }
    qrfc_in     = @{ warn=1;  crit=100; label='inbound qRFC queue entries (TRFCQIN)' }
    qrfc_out    = @{ warn=1;  crit=100; label='outbound qRFC queue entries (TRFCQOUT)' }
    trfc        = @{ warn=1;  crit=200; label='pending/failed tRFC LUWs (ARFCSSTATE)' }
    batch_input = @{ warn=1;  crit=50;  label='batch-input sessions (APQI)' }
    locks       = @{ warn=20; crit=200; label='enqueue locks (ENQUE_READ)' }
    imports     = @{ warn=1;  crit=1;   label='transport imports running (TRBAT)' }
}
if ($Defaults -and (Test-Path $Defaults)) {
    try { $j = Get-Content $Defaults -Raw | ConvertFrom-Json; foreach ($k in $TH.Keys) { if ($j.$k) { if ($j.$k.warn -ne $null){$TH[$k].warn=[int]$j.$k.warn}; if ($j.$k.crit -ne $null){$TH[$k].crit=[int]$j.$k.crit}; if ($j.$k.label){$TH[$k].label="$($j.$k.label)"} } } } catch { }
}
function Sev { param([int]$n,$t) if ($n -ge $t.crit) { 'HIGH' } elseif ($n -ge $t.warn) { 'MEDIUM' } elseif ($n -gt 0) { 'LOW' } else { 'INFO' } }

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $OutDir) { Write-Host 'STATUS: RFC_ERROR no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$dest = $null
try {
    if ($System) {
        $cands = @(Resolve-SapProfileHint -Hint $System)
        if ($cands.Count -ne 1) { Write-Host ("STATUS: RFC_LOGON_FAILED reason=profile_{0}_ambiguous" -f $System); exit 2 }
        $t = $cands[0]; $pw = (& (Join-Path $scripts 'sap_dpapi.ps1') -Action unprotect -Value "$($t.password_dpapi)" 2>$null) -as [string]
        $dest = Connect-SapRfc -Server $t.application_server -Sysnr $t.system_number -MessageServer $t.message_server -LogonGroup $t.logon_group -SystemID $t.system_id -Client $t.client -User $t.user -Password $pw -Language $t.language -DestName 'CUT_HEALTH'
    } else { $dest = Connect-SapRfc -DestName 'CUT_HEALTH' }
} catch { }
if (-not $dest) { Write-Host 'STATUS: RFC_LOGON_FAILED'; exit 2 }

$SID=''; try { $si=$dest.Repository.CreateFunction('RFC_SYSTEM_INFO'); $si.Invoke($dest); $SID=(San $si.GetStructure('RFCSI_EXPORT').GetString('RFCSYSID')) } catch { }
$rows=@()
function Probe { param($name,[scriptblock]$body)
    try { $n = & $body; $t=$TH[$name]; $sev=(Sev $n $t); Write-Host ("HEALTH: probe={0} count={1} severity={2} coverage=CHECKED label=`"{3}`"" -f $name,$n,$sev,$t.label); $script:rows += ("{0}`t{1}`t{2}`tCHECKED`t{3}" -f $name,$n,$sev,$t.label) }
    catch { Write-Host ("HEALTH: probe={0} count=0 severity=INFO coverage=COULD_NOT_CHECK label=`"{1}`"" -f $name,$TH[$name].label); $script:rows += ("{0}`t0`tINFO`tCOULD_NOT_CHECK`t{1}" -f $name,$TH[$name].label) }
}

try {
    $dumpWhere = "SEQNO = '000'"; if ($StartDate) { $dumpWhere = "SEQNO = '000' AND DATUM GE '$StartDate'" }
    Probe 'dumps'       { Count-Rows $dest 'SNAP' 'DATUM' $dumpWhere }
    Probe 'updates'     { Count-Rows $dest 'VBHDR' 'VBKEY' '' }
    Probe 'qrfc_in'     { Count-Rows $dest 'TRFCQIN' 'MANDT' '' }
    Probe 'qrfc_out'    { Count-Rows $dest 'TRFCQOUT' 'MANDT' '' }
    Probe 'trfc'        { Count-Rows $dest 'ARFCSSTATE' 'ARFCIPID' '' }
    Probe 'batch_input' { Count-Rows $dest 'APQI' 'DESTSYS' '' }
    Probe 'locks'       { $er=$dest.Repository.CreateFunction('ENQUE_READ'); $er.SetValue('GCLIENT',''); $er.SetValue('GUNAME',''); $er.Invoke($dest); $er.GetTable('ENQ').RowCount }
    Probe 'imports'     { Count-Rows $dest 'TRBAT' 'TRKORR' '' }

    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $sb=New-Object System.Text.StringBuilder; [void]$sb.AppendLine("probe`tcount`tseverity`tcoverage`tlabel")
    foreach ($r in $rows) { [void]$sb.AppendLine($r) }
    [IO.File]::WriteAllText((Join-Path $OutDir ("health_{0}.tsv" -f $stamp)), $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
    Write-Host ("STATUS: OK sid=$SID probes=8")
    Disconnect-SapRfc; exit 0
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch {}; exit 2
}
