# =============================================================================
# sap_gateway_read.ps1  -  OData/Gateway service status + error-log reader (/sap-gateway-service)
#
# Read-only RFC (RFC_READ_TABLE FMODE=R, probed S4D 2026-07-11). S/4-only: the /IWFND/* hub
# catalog exists on S4D but NOT on ECC (EC2 is backend-only). Preflight distinguishes:
#   /IWFND/I_MED_SRH present         -> proceed
#   absent but /IWBEP/I_MGW_SRH present -> GW_BACKEND_ONLY (hub is on another box; use /sap-login)
#   both absent                      -> GW_NOT_INSTALLED
#
#   status  /IWFND/I_MED_SRH (registration + IS_ACTIVE) x /IWFND/V_MGDEAM (system-alias) per
#           service -> verdict OK | INACTIVE | NO_ALIAS | NOT_REGISTERED. A missing alias is the
#           classic 500 cause.
#   errors  /IWFND/SU_ERRLOG list (T100 msg + ERROR_TEXT + SOURCE_PROGRAM/INCLUDE/LINE +
#           SERVICE_NAME + REQUEST_URI) -> the error cause is in the row (no GUI needed for the
#           list); ERROR_CONTEXT (RSTR) is the --deep GUI leg. Cluster by (service,msgid,msgno).
#
#   -Action status [-Service <name>]  |  -Action errors [-Service <n>] [-User U] [-Date YYYYMMDD] [-Top N]
#   [-Profile <hint>] -OutDir <dir>
# stdout: GWPRE:/GWSVC:/GWERR: lines + STATUS: OK|GW_NOT_INSTALLED|GW_BACKEND_ONLY|RFC_*. Exit 0/1/2.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Action    = 'status',
    [string] $Service   = '',
    [string] $User      = '',
    [string] $Date      = '',
    [int]    $Top       = 50,
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
function Exists-Table { param($d,[string]$t) $r=@(Read-Rows $d 'DD02L' "TABNAME = '$t'" @('TABNAME') 1); return ($r.Count -gt 0) }

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $OutDir) { Write-Host 'STATUS: GW_INPUT no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$d = $null
if ($Profile) {
    $cands = @(Resolve-SapProfileHint -Hint $Profile)
    if ($cands.Count -ne 1) { Write-Host "STATUS: RFC_LOGON_FAILED profile=$Profile"; exit 2 }
    $c = $cands[0]; $pw = (& (Join-Path $scripts 'sap_dpapi.ps1') -Action unprotect -Value "$($c.password_dpapi)" 2>$null) -as [string]
    try { $d = Connect-SapRfc -Server $c.application_server -Sysnr $c.system_number -MessageServer $c.message_server -LogonGroup $c.logon_group -SystemID $c.system_id -Client $c.client -User $c.user -Password $pw -Language $c.language -DestName ("GW_"+$c.system_name) } catch { }
} else { try { $d = Connect-SapRfc -DestName 'GW' } catch { } }
if (-not $d) { Write-Host 'STATUS: RFC_LOGON_FAILED'; exit 2 }

try {
    # --- preflight: hub present? ---
    $hub = '/IWFND/I_MED_SRH'
    if (-not (Exists-Table $d $hub)) {
        if (Exists-Table $d '/IWBEP/I_MGW_SRH') { Write-Host 'GWPRE: hub=absent backend=present'; Write-Host 'STATUS: GW_BACKEND_ONLY (Gateway hub is on another system; pin the hub via /sap-login)'; Disconnect-SapRfc; exit 1 }
        Write-Host 'GWPRE: hub=absent backend=absent'; Write-Host 'STATUS: GW_NOT_INSTALLED'; Disconnect-SapRfc; exit 1
    }
    Write-Host 'GWPRE: hub=present'

    if ($Action -eq 'status') {
        $w = @("IS_ACTIVE = 'A'")   # 'A' = active model row (probed) -- the registration truth
        if ($Service) { $w = @("SERVICE_NAME = '$($Service.ToUpper())'") }
        $svc = @(Read-Rows $d $hub ($w -join ' AND ') @('SRV_IDENTIFIER','IS_ACTIVE','NAMESPACE','SERVICE_NAME','SERVICE_VERSION','IS_SAP_SERVICE') ([Math]::Max(1,$Top)))
        if ($Service -and $svc.Count -eq 0) { Write-Host "STATUS: GW_SERVICE_NOT_FOUND service=$Service"; Disconnect-SapRfc; exit 1 }
        # alias assignments (one read, keyed by SERVICE_ID)
        $aliasMap=@{}
        $al = @(Read-Rows $d '/IWFND/V_MGDEAM' '' @('SERVICE_ID','SYSTEM_ALIAS','IS_DEFAULT') 5000)
        foreach ($a in $al) { $sid=San $a.SERVICE_ID; if ($sid) { if (-not $aliasMap.ContainsKey($sid)) { $aliasMap[$sid]=@() }; $aliasMap[$sid] += "$(San $a.SYSTEM_ALIAS)$(if((San $a.IS_DEFAULT) -eq 'X'){'(def)'}else{''})" } }
        $lines=@()
        foreach ($s in $svc) {
            $sid=San $s.SRV_IDENTIFIER; $sn=San $s.SERVICE_NAME; $act=San $s.IS_ACTIVE
            $aliases = if ($aliasMap.ContainsKey($sid)) { ($aliasMap[$sid] | Select-Object -Unique) -join ',' } else { '' }
            $verdict = if ($act -ne 'A') { 'INACTIVE' } elseif (-not $aliases) { 'NO_ALIAS' } else { 'OK' }
            Write-Host ("GWSVC: service=$sn active=$act alias=`"$aliases`" version=$(San $s.SERVICE_VERSION) sap=$(San $s.IS_SAP_SERVICE) verdict=$verdict")
            $lines += (@($sn,$act,$aliases,(San $s.SERVICE_VERSION),(San $s.IS_SAP_SERVICE),(San $s.NAMESPACE),$verdict) -join "`t")
        }
        $sb=New-Object System.Text.StringBuilder;[void]$sb.AppendLine("service`tactive`talias`tversion`tis_sap`tnamespace`tverdict");foreach($l in $lines){[void]$sb.AppendLine($l)}
        [IO.File]::WriteAllText((Join-Path $OutDir 'gw_status.tsv'),$sb.ToString(),(New-Object Text.UTF8Encoding($true)))
        Write-Host ("STATUS: OK services=$($svc.Count)")
        Disconnect-SapRfc; exit 0
    }
    elseif ($Action -eq 'errors') {
        $w=@()
        if ($User)    { $w += "USERNAME = '$($User.ToUpper())'" }
        if ($Service) { $w += "SERVICE_NAME = '$($Service.ToUpper())'" }
        if ($Date)    { $w += "FIRST_TSTMP GE '$Date" + "000000000000000'" }
        # BUILD FINDING (S4D 2026-07-11): /IWFND/SU_ERRLOG is NOT readable via RFC_READ_TABLE OR
        # BBP_RFC_READ_TABLE -- its RSTR/STRG columns (ERROR_CONTEXT, HTML_PAGE) trip an
        # ASSIGN-CASTING dump in SAPLSDTX/SAPLBBPB regardless of the requested field list. So the
        # errors LIST source is the /IWFND/ERROR_LOG GUI scrape (SKILL.md Step 4b, NEEDS_RECORDING),
        # not a table read. Detect + report honestly rather than emitting a raw RFC_ERROR.
        $rows = @()
        try { $rows = @(Read-Rows $d '/IWFND/SU_ERRLOG' ($w -join ' AND ') @('TIMESTAMP','USERNAME','T100_MSGID','T100_MSGNO','ERROR_TEXT','SERVICE_NAME','SOURCE_PROGRAM','SOURCE_LINE') ([Math]::Max(1,$Top*4))) }
        catch { if ("$($_.Exception.Message)" -match 'CASTING|SAPLSDTX') { Write-Host 'GWERR: SU_ERRLOG not RFC-readable (string columns) -> use the /IWFND/ERROR_LOG GUI scrape (errors --deep)'; Write-Host 'STATUS: GW_ERRLOG_GUI_ONLY'; Disconnect-SapRfc; exit 1 } else { throw } }
        $rows = @($rows | Sort-Object { $_.TIMESTAMP } -Descending | Select-Object -First $Top)
        foreach ($r in $rows) { Write-Host ("GWERR: time=$(San $r.TIMESTAMP) user=$(San $r.USERNAME) service=$(San $r.SERVICE_NAME) msg=$(San $r.T100_MSGID)-$(San $r.T100_MSGNO) prog=$(San $r.SOURCE_PROGRAM) line=$(San $r.SOURCE_LINE) text=`"$(San $r.ERROR_TEXT)`"") }
        # cluster by (service,msgid,msgno)
        $grp=@{}
        foreach ($r in $rows) { $k="$(San $r.SERVICE_NAME)|$(San $r.T100_MSGID)-$(San $r.T100_MSGNO)"; if(-not $grp.ContainsKey($k)){$grp[$k]=@{n=0;svc=(San $r.SERVICE_NAME);msg="$(San $r.T100_MSGID)-$(San $r.T100_MSGNO)";prog=(San $r.SOURCE_PROGRAM);text=(San $r.ERROR_TEXT)}}; $grp[$k].n++ }
        $cl=@()
        foreach ($k in ($grp.Keys | Sort-Object { $grp[$_].n } -Descending)) { $g=$grp[$k]
            # cause heuristic: a named DPC/MPC source program -> custom code; else config
            $cause = if ($g.prog -match '(?i)DPC|MPC|CL_Z|CL_Y|^Z|^Y') { 'CUSTOM_CODE' } elseif ($g.text -match '(?i)alias|system alias') { 'NO_ALIAS' } elseif ($g.text -match '(?i)auth') { 'AUTH' } elseif ($g.text -match '(?i)metadata') { 'METADATA_CACHE' } else { 'CONFIG_OR_OTHER' }
            Write-Host ("GWCLUSTER: service=$($g.svc) msg=$($g.msg) count=$($g.n) cause=$cause prog=$($g.prog) text=`"$($g.text)`"")
            $cl += (@($g.svc,$g.msg,$g.n,$cause,$g.prog,$g.text) -join "`t")
        }
        $sb=New-Object System.Text.StringBuilder;[void]$sb.AppendLine("service`tmessage`tcount`tcause`tsource_program`terror_text");foreach($l in $cl){[void]$sb.AppendLine($l)}
        [IO.File]::WriteAllText((Join-Path $OutDir 'gw_errors.tsv'),$sb.ToString(),(New-Object Text.UTF8Encoding($true)))
        Write-Host ("STATUS: OK errors=$($rows.Count) clusters=$($grp.Count)")
        Disconnect-SapRfc; exit 0
    }
    else { Write-Host "STATUS: GW_INPUT bad_action=$Action"; Disconnect-SapRfc; exit 2 }
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
