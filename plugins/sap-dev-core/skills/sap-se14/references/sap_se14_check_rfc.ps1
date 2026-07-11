# =============================================================================
# sap_se14_check_rfc.ps1  -  SE14 (DB Utility) DDIC-vs-DB consistency snapshot (/sap-se14 check)
#
# Read-only RFC (RFC_READ_TABLE FMODE=R, all tables probed identical S4D + EC2 2026-07-11).
# Runs a fixed battery and returns a verdict, so a failed table activation can auto-chain here
# safely. Also the post-verify read for the GUI adjust/unlock write modes.
#
# Battery: DD02L (active row + TABCLASS + any pending non-'A' version), DWINACTIV (inactive
# worklist), TBATG (open DB-utility/conversion request -> SEVERITY state + FCT), DBDIFF (DDIC/DB
# diff), DDXTT (inactive nametab), DD02L for QCM<T>/QCM8<T> (surviving shadow table = conversion
# in flight/terminated), DDPRH (newest SDIC log header). Verdict:
#   NOT_FOUND | CONSISTENT | ADJUST_NEEDED | CONVERSION_RUNNING | CONVERSION_TERMINATED
# (DB_EXISTS_TABLE/DD_EXISTS_DATA are FMODE-blank -> reported COULD_NOT_CHECK; the wrapper path
# is optional and never auto-deployed.)
#
#   -Table <TAB> [-Profile <hint>] -OutDir <dir>
# stdout: SE14: CHECK <probe>=<state> lines + SE14: VERDICT <v> + STATUS: OK. Exit 0/2.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Table     = '',
    [string] $Profile   = '',
    [string] $OutDir    = '',
    [string] $SharedDir = '',
    [string] $RunId     = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\shared')).Path } catch { $SharedDir = '' } }
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
if (-not $Table)  { Write-Host 'STATUS: SE14_INPUT no_table'; exit 2 }
if (-not $OutDir) { Write-Host 'STATUS: SE14_INPUT no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$tab = $Table.ToUpper()

$d = $null
if ($Profile) {
    $cands = @(Resolve-SapProfileHint -Hint $Profile)
    if ($cands.Count -ne 1) { Write-Host "STATUS: RFC_LOGON_FAILED profile=$Profile"; exit 2 }
    $c = $cands[0]; $pw = (& (Join-Path $scripts 'sap_dpapi.ps1') -Action unprotect -Value "$($c.password_dpapi)" 2>$null) -as [string]
    try { $d = Connect-SapRfc -Server $c.application_server -Sysnr $c.system_number -MessageServer $c.message_server -LogonGroup $c.logon_group -SystemID $c.system_id -Client $c.client -User $c.user -Password $pw -Language $c.language -DestName ("SE14_"+$c.system_name) } catch { }
} else { try { $d = Connect-SapRfc -DestName 'SE14' } catch { } }
if (-not $d) { Write-Host 'STATUS: RFC_LOGON_FAILED'; exit 2 }

try {
    $probes=@()
    function P { param($name,$state,$detail) $script:probes += ,([pscustomobject]@{ probe=$name; state=$state; detail=$detail }); Write-Host ("SE14: CHECK $name=$state $detail") }

    # DD02L: active row + tabclass + pending version
    $act = @(Read-Rows $d 'DD02L' "TABNAME = '$tab' AND AS4LOCAL = 'A' AND AS4VERS = '0000'" @('TABNAME','TABCLASS','AS4LOCAL') 1)
    $anyVer = @(Read-Rows $d 'DD02L' "TABNAME = '$tab'" @('AS4LOCAL','AS4VERS','TABCLASS') 10)
    $tabclass = if ($act.Count) { San $act[0].TABCLASS } elseif ($anyVer.Count) { San $anyVer[0].TABCLASS } else { '' }
    if (-not $anyVer.Count) { P 'DD02L' 'NOT_FOUND' ''; Write-Host 'SE14: VERDICT NOT_FOUND'; $verdict='NOT_FOUND' }
    else {
        $pending = @($anyVer | Where-Object { (San $_.AS4LOCAL) -ne 'A' })
        P 'DD02L' $(if($act.Count){'ACTIVE'}else{'NO_ACTIVE'}) "tabclass=$tabclass pending_versions=$($pending.Count)"

        $dwin = @(Read-Rows $d 'DWINACTIV' "OBJ_NAME = '$tab'" @('OBJECT','OBJ_NAME','UNAME') 10)
        P 'DWINACTIV' $(if($dwin.Count){'INACTIVE'}else{'CLEAN'}) $(if($dwin.Count){"by=$(San $dwin[0].UNAME)"}else{''})

        $tbatg = @(Read-Rows $d 'TBATG' "TABNAME = '$tab'" @('OBJECT','TABNAME','FCT','SEVERITY','FCT_DETAIL','GDATE') 20)
        $tbState=''; if ($tbatg.Count) { $tbState = San $tbatg[0].SEVERITY }
        P 'TBATG' $(if($tbatg.Count){"OPEN($($tbatg.Count))"}else{'NONE'}) $(if($tbatg.Count){"fct=$(San $tbatg[0].FCT) severity=$tbState date=$(San $tbatg[0].GDATE)"}else{''})

        $dbdiff = @(Read-Rows $d 'DBDIFF' "OBJNAME = '$tab'" @('OBJNAME','DIFFKIND') 5)
        P 'DBDIFF' $(if($dbdiff.Count){'DIFF'}else{'CLEAN'}) ''

        # DDXTT (inactive nametab) is deliberately NOT read over RFC: the nametab tables carry
        # binary RAW columns that make RFC_READ_TABLE raise an ASSIGN-CASTING dump in SAPLSDTX
        # (verified S4D 2026-07-11), and DWINACTIV + pending-version already cover "inactive".

        $qcm = @(Read-Rows $d 'DD02L' "TABNAME = 'QCM$tab' OR TABNAME = 'QCM8$tab'" @('TABNAME') 3)
        P 'QCM_SHADOW' $(if($qcm.Count){'PRESENT'}else{'NONE'}) $(if($qcm.Count){"$(San $qcm[0].TABNAME)"}else{''})

        $ddprh = @(Read-Rows $d 'DDPRH' "PROTNAME LIKE '%$tab%'" @('PROTNAME','AS4DATE','MAXSEVER') 5)
        P 'DDPRH_LOG' $(if($ddprh.Count){"MAXSEVER=$(San $ddprh[0].MAXSEVER)"}else{'NONE'}) $(if($ddprh.Count){"log=$(San $ddprh[0].PROTNAME)"}else{''})

        # DB-side existence: FMODE-blank FMs need the wrapper -> report COULD_NOT_CHECK in v1
        P 'DB_EXISTS' 'COULD_NOT_CHECK' 'DB_EXISTS_TABLE/DD_EXISTS_DATA are FMODE-blank (optional wrapper path, v1.5)'

        # verdict
        if ($tbatg.Count -and $qcm.Count) { $verdict = if ($tbState -match '[EAX]') { 'CONVERSION_TERMINATED' } else { 'CONVERSION_RUNNING' } }
        elseif ($tbatg.Count) { $verdict = if ($tbState -match '[EAX]') { 'CONVERSION_TERMINATED' } else { 'CONVERSION_RUNNING' } }
        elseif ($qcm.Count) { $verdict = 'CONVERSION_TERMINATED' }
        elseif ($dwin.Count -or $pending.Count -or $dbdiff.Count) { $verdict = 'ADJUST_NEEDED' }
        else { $verdict = 'CONSISTENT' }
        Write-Host "SE14: VERDICT $verdict"
    }

    $sb=New-Object System.Text.StringBuilder;[void]$sb.AppendLine("# SE14 check table=$tab verdict=$verdict");[void]$sb.AppendLine("probe`tstate`tdetail")
    foreach ($p in $probes) { [void]$sb.AppendLine((@($p.probe,$p.state,$p.detail) -join "`t")) }
    [IO.File]::WriteAllText((Join-Path $OutDir "se14_check_$tab.tsv"), $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
    Write-Host "STATUS: OK verdict=$verdict"
    Disconnect-SapRfc; exit 0
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
