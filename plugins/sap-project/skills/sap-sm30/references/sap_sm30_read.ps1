# =============================================================================
# sap_sm30_read.ps1  -  SM30 view resolve + pre-read + verify (read-only RFC) for /sap-sm30
#
# Read-only RFC (RFC_READ_TABLE FMODE=R, all tables probed identical S4D + EC2 2026-07-11).
# The read/verify half of the skill; the write half is SM30's own generated GUI dialog.
#
#   resolve  TVDIR (maintenance dialog: TYPE 1=one-step / 2=two-step, AREA=function group,
#            CLTCODE), DD25L (view class), DD26S (base tables -> primary), DD27S (view field ->
#            base field + KEYFLAG), TDDAT (S_TABU_DIS auth group), T000 (client modifiability).
#            -> SM30INFO: lines + a maintainability verdict (v1 supports one-step views only).
#   preread  reads the primary base table projected to the view's base fields, optional -Where,
#            -> snapshot TSV (the "before" for the preview diff / the write-mode verify baseline).
#
#   -Action resolve|preread  -Object <VIEW|TABLE>  [-Where "F=V,F=V"] [-Max 200]
#   [-Profile <hint>] -OutDir <dir>
# stdout: SM30INFO:/SM30ROW: lines + SM30: VERDICT <v> + STATUS: OK|SM30_*. Exit 0/1/2.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Action    = 'resolve',
    [string] $Object    = '',
    [string] $Where     = '',
    [int]    $Max       = 200,
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
function Build-Where { param([string]$w) if (-not $w) { return '' }; $p=@(); foreach ($t in ($w -split ',')) { $t=$t.Trim(); if ($t -match '^\s*([A-Za-z0-9_/]+)\s*=\s*(.+?)\s*$') { $p += ("{0} = '{1}'" -f $matches[1].ToUpper(),$matches[2].Trim()) } }; return ($p -join ' AND ') }

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $Object) { Write-Host 'STATUS: SM30_INPUT no_object'; exit 2 }
if (-not $OutDir) { Write-Host 'STATUS: SM30_INPUT no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$obj = $Object.ToUpper()

$d = $null
if ($Profile) {
    $cands = @(Resolve-SapProfileHint -Hint $Profile)
    if ($cands.Count -ne 1) { Write-Host "STATUS: RFC_LOGON_FAILED profile=$Profile"; exit 2 }
    $c = $cands[0]; $pw = (& (Join-Path $scripts 'sap_dpapi.ps1') -Action unprotect -Value "$($c.password_dpapi)" 2>$null) -as [string]
    try { $d = Connect-SapRfc -Server $c.application_server -Sysnr $c.system_number -MessageServer $c.message_server -LogonGroup $c.logon_group -SystemID $c.system_id -Client $c.client -User $c.user -Password $pw -Language $c.language -DestName ("SM30_"+$c.system_name) } catch { }
} else { try { $d = Connect-SapRfc -DestName 'SM30' } catch { } }
if (-not $d) { Write-Host 'STATUS: RFC_LOGON_FAILED'; exit 2 }

try {
    # --- TVDIR maintenance-dialog registration ---
    $tv = @(Read-Rows $d 'TVDIR' "TABNAME = '$obj'" @('TABNAME','AREA','TYPE','CLTCODE','BASTAB') 1)
    if (-not $tv.Count) { Write-Host "SM30: VERDICT SM30_NO_MAINT_DIALOG"; Write-Host "STATUS: SM30_NO_MAINT_DIALOG object=$obj"; Disconnect-SapRfc; exit 1 }
    $type=San $tv[0].TYPE; $area=San $tv[0].AREA; $isTable=((San $tv[0].BASTAB) -eq 'X')
    Write-Host ("SM30INFO: object=$obj kind=$(if($isTable){'TABLE'}else{'VIEW'}) maint_type=$type function_group=$area maint_tcode=$(San $tv[0].CLTCODE)")

    # --- fields + keys (DD27S) + base tables (DD26S) ---
    $flds = @(Read-Rows $d 'DD27S' "VIEWNAME = '$obj' AND AS4LOCAL = 'A'" @('OBJPOS','VIEWFIELD','TABNAME','FIELDNAME','KEYFLAG','RDONLY') 300 | Sort-Object { [int]("0"+$_.OBJPOS) })
    $bases = @(Read-Rows $d 'DD26S' "VIEWNAME = '$obj' AND AS4LOCAL = 'A'" @('TABNAME','TABPOS') 20 | Sort-Object { [int]("0"+$_.TABPOS) })
    $primary = if ($bases.Count) { San $bases[0].TABNAME } elseif ($isTable) { $obj } else { '' }
    $keys = @($flds | Where-Object { (San $_.KEYFLAG) -eq 'X' } | ForEach-Object { San $_.VIEWFIELD })
    Write-Host ("SM30INFO: primary_table=$primary base_tables=$(($bases | ForEach-Object { San $_.TABNAME }) -join ',') fields=$($flds.Count) keys=$($keys -join ',')")

    # --- auth group (TDDAT) + client modifiability (T000) ---
    $td = @(Read-Rows $d 'TDDAT' "TABNAME = '$primary'" @('TABNAME','CCLASS') 1)
    $authgrp = if ($td.Count) { San $td[0].CCLASS } else { '' }
    $cli=''; try { $cr = @(Read-Rows $d 'USR02' '' @('MANDT') 1); if ($cr.Count) { $cli=$cr[0].MANDT } } catch { }
    $t0 = @(Read-Rows $d 'T000' "MANDT = '$cli'" @('MANDT','CCCATEGORY','CCCORACTIV') 1)
    $ccat = if ($t0.Count) { San $t0[0].CCCATEGORY } else { '' }
    Write-Host ("SM30INFO: auth_group=$authgrp client=$cli client_category=$ccat")

    # --- maintainability verdict (v1 = one-step views only) ---
    $verdict = if ($type -eq '2') { 'SM30_TWO_STEP_UNSUPPORTED' } elseif (-not $primary) { 'SM30_NO_BASE_TABLE' } else { 'MAINTAINABLE_V1' }
    Write-Host ("SM30: VERDICT $verdict")

    if ($Action -eq 'preread') {
        if (-not $primary) { Write-Host 'STATUS: SM30_NO_BASE_TABLE'; Disconnect-SapRfc; exit 1 }
        # project to the view's base fields on the primary table
        $baseFields = @($flds | Where-Object { (San $_.TABNAME) -eq $primary -and (San $_.FIELDNAME) } | ForEach-Object { San $_.FIELDNAME } | Select-Object -Unique)
        if ($baseFields.Count -eq 0) { $baseFields = @($keys) }
        $where = Build-Where $Where
        $rows = @(Read-Rows $d $primary $where $baseFields $Max)
        Write-Host ("SM30INFO: preread table=$primary fields=$($baseFields.Count) rows=$($rows.Count) capped=$(if($rows.Count -ge $Max){'Y'}else{'N'})")
        $sb=New-Object System.Text.StringBuilder;[void]$sb.AppendLine(($baseFields -join "`t"))
        foreach ($r in $rows) { [void]$sb.AppendLine((($baseFields | ForEach-Object { San $r.$_ }) -join "`t")); Write-Host ("SM30ROW: " + (($baseFields | Select-Object -First 6 | ForEach-Object { "$($_)=$(San $r.$_)" }) -join ' | ')) }
        [IO.File]::WriteAllText((Join-Path $OutDir "sm30_$($obj)_preread.tsv"), $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
    }
    Write-Host "STATUS: OK verdict=$verdict"
    Disconnect-SapRfc; exit 0
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
