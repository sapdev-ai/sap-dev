# =============================================================================
# sap_pfcg_verify.ps1  -  PFCG role snapshot + write-gate re-read (/sap-pfcg) (read-only RFC)
#
# Read-only RFC (RFC_READ_TABLE FMODE=R, all AGR_* + T000 probed identical S4D + EC2 2026-07-11).
# The role dossier (show) AND the authoritative post-write re-read that every write mode verdicts
# against (RFC re-read beats GUI status text -- a status 'S' with an unexpected AGR_TCODES delta is
# still PFCG_VERIFY_MISMATCH).
#
#   -Mode snapshot  -Role <R>  [-Profile <hint>] -OutDir <dir>
#   -Mode list      [-Filter Z*]              (enumerate roles)
#
# Reads: AGR_DEFINE (exists), AGR_TEXTS (description), AGR_TCODES (menu tcodes), AGR_USERS
# (assignments + validity), AGR_PROF (generated profile), AGR_1251 (auth row count), T000
# (client modifiability for the write gate).
#
# stdout: PFCG:/PFCGTCODE:/PFCGUSER: lines + PFCG: VERDICT <..> + STATUS: OK|AUTH_ROLE_NOT_FOUND.
# Exit 0/1/2.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Mode      = 'snapshot',
    [string] $Role      = '',
    [string] $Filter    = 'Z*',
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

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $OutDir) { Write-Host 'STATUS: PFCG_INPUT no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$d = $null
if ($Profile) {
    $cands = @(Resolve-SapProfileHint -Hint $Profile)
    if ($cands.Count -ne 1) { Write-Host "STATUS: RFC_LOGON_FAILED profile=$Profile"; exit 2 }
    $c = $cands[0]; $pw = (& (Join-Path $scripts 'sap_dpapi.ps1') -Action unprotect -Value "$($c.password_dpapi)" 2>$null) -as [string]
    try { $d = Connect-SapRfc -Server $c.application_server -Sysnr $c.system_number -MessageServer $c.message_server -LogonGroup $c.logon_group -SystemID $c.system_id -Client $c.client -User $c.user -Password $pw -Language $c.language -DestName ("PFCG_"+$c.system_name) } catch { }
} else { try { $d = Connect-SapRfc -DestName 'PFCG' } catch { } }
if (-not $d) { Write-Host 'STATUS: RFC_LOGON_FAILED'; exit 2 }

try {
    if ($Mode -eq 'list') {
        $where = if ($Filter -match '[*%]') { "AGR_NAME LIKE '$($Filter -replace '\*','%')'" } else { '' }
        $roles = @(Read-Rows $d 'AGR_DEFINE' $where @('AGR_NAME','PARENT_AGR') 200)
        foreach ($r in $roles) { Write-Host ("PFCG: role=$(San $r.AGR_NAME) parent=$(San $r.PARENT_AGR)") }
        Write-Host ("STATUS: OK roles=$($roles.Count)")
        Disconnect-SapRfc; exit 0
    }
    # --- snapshot ---
    if (-not $Role) { Write-Host 'STATUS: PFCG_INPUT no_role'; Disconnect-SapRfc; exit 2 }
    $r = $Role.ToUpper()
    $def = @(Read-Rows $d 'AGR_DEFINE' "AGR_NAME = '$r'" @('AGR_NAME','PARENT_AGR') 1)
    if (-not $def.Count) { Write-Host "PFCG: VERDICT AUTH_ROLE_NOT_FOUND"; Write-Host "STATUS: AUTH_ROLE_NOT_FOUND role=$r"; Disconnect-SapRfc; exit 1 }
    $isComposite = [bool](San $def[0].PARENT_AGR)   # a composite role has children; PARENT_AGR set = it IS a child
    # description
    $txt=''; foreach ($lang in @('E','D','1')) { $t = @(Read-Rows $d 'AGR_TEXTS' "AGR_NAME = '$r' AND SPRAS = '$lang' AND LINE = '00000'" @('TEXT') 1); if ($t.Count) { $txt=San $t[0].TEXT; break } }
    if (-not $txt) { $t = @(Read-Rows $d 'AGR_TEXTS' "AGR_NAME = '$r'" @('TEXT') 1); if ($t.Count) { $txt=San $t[0].TEXT } }
    Write-Host ("PFCG: role=$r desc=`"$txt`" parent=$(San $def[0].PARENT_AGR)")
    # tcodes
    $tc = @(Read-Rows $d 'AGR_TCODES' "AGR_NAME = '$r'" @('TCODE','TYPE') 2000)
    Write-Host ("PFCG: menu_tcodes=$($tc.Count)")
    foreach ($t in ($tc | Select-Object -First 40)) { Write-Host ("PFCGTCODE: $(San $t.TCODE)") }
    # users
    $us = @(Read-Rows $d 'AGR_USERS' "AGR_NAME = '$r'" @('UNAME','FROM_DAT','TO_DAT') 2000)
    Write-Host ("PFCG: assigned_users=$($us.Count)")
    foreach ($u in ($us | Select-Object -First 40)) { Write-Host ("PFCGUSER: $(San $u.UNAME) valid=$(San $u.FROM_DAT)..$(San $u.TO_DAT)") }
    # profile + auth rows
    $prof = @(Read-Rows $d 'AGR_PROF' "AGR_NAME = '$r'" @('PROFILE') 5)
    $auth = @(Read-Rows $d 'AGR_1251' "AGR_NAME = '$r'" @('OBJECT') 5000)
    $profName = if ($prof.Count) { San $prof[0].PROFILE } else { '' }
    Write-Host ("PFCG: generated_profile=$profName auth_rows=$($auth.Count) generated=$(if($profName){'YES'}else{'NO'})")
    # client modifiability (write gate input)
    $cli=''; try { $cr = @(Read-Rows $d 'USR02' '' @('MANDT') 1); if ($cr.Count) { $cli=$cr[0].MANDT } } catch { }
    $t0 = @(Read-Rows $d 'T000' "MANDT = '$cli'" @('CCCATEGORY','CCCORACTIV') 1)
    $ccat = if ($t0.Count) { San $t0[0].CCCATEGORY } else { '' }; $ccor = if ($t0.Count) { San $t0[0].CCCORACTIV } else { '' }
    $modifiable = ($ccor -ne '2' -and $ccor -ne '3')   # 2/3 = no changes / no transports+repository
    Write-Host ("PFCG: client=$cli category=$ccat cust_changes=$ccor modifiable=$(if($modifiable){'YES'}else{'NO'})")

    # write TSVs
    $sb=New-Object System.Text.StringBuilder;[void]$sb.AppendLine("kind`tvalue");[void]$sb.AppendLine("role`t$r");[void]$sb.AppendLine("description`t$txt");[void]$sb.AppendLine("profile`t$profName");[void]$sb.AppendLine("auth_rows`t$($auth.Count)")
    foreach ($t in $tc) { [void]$sb.AppendLine("tcode`t$(San $t.TCODE)") }
    foreach ($u in $us) { [void]$sb.AppendLine("user`t$(San $u.UNAME)") }
    [IO.File]::WriteAllText((Join-Path $OutDir "role_snapshot_$r.tsv"), $sb.ToString(), (New-Object Text.UTF8Encoding($true)))

    $verdict = if (-not $profName) { 'NOT_GENERATED' } else { 'OK' }
    Write-Host ("PFCG: VERDICT $verdict composite=$(if($isComposite){'YES'}else{'NO'})")
    Write-Host ("STATUS: OK role=$r tcodes=$($tc.Count) users=$($us.Count)")
    Disconnect-SapRfc; exit 0
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
