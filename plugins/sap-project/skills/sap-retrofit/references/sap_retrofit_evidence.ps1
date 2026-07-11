# =============================================================================
# sap_retrofit_evidence.ps1  -  project-line change evidence per object for /sap-retrofit
#
# Connects the PROJECT line (pinned profile) and gathers read-only change evidence per object
# so classify can decide GREEN (project untouched) vs YELLOW (project also changed). Tri-state
# per source: an unreadable source is COULD_NOT_CHECK, never a silent CLEAN (which would risk a
# false GREEN / overwritten fix). Pure RFC (VRSD/E071/E070/TADIR, all FMODE=R / TRANSP).
#
#   -Objects "TYPE:NAME,TYPE:NAME" -Baseline <YYYYMMDD> [-SharedDir <dir>] [-RunId <id>]
#
# stdout: EVIDENCE: object=<type> obj_name=<n> tadir=<EXISTS|ABSENT|COULD_NOT_CHECK>
#              vrsd=<CLEAN|HIT:<n>|COULD_NOT_CHECK> e071=<CLEAN|HIT:<tr>|COULD_NOT_CHECK>
#         STATUS: OK objs=<n> sid=<SID> | RFC_LOGON_FAILED | RFC_ERROR  ; exit 0/2
# =============================================================================
[CmdletBinding()]
param(
    [string] $Objects   = '',
    [string] $Baseline  = '',
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
function Invoke-Rfc { param($fn,$d) try { $fn.Invoke($d); return $true } catch { $m="$($_.Exception.Message)"; if ($m -match 'TABLE_WITHOUT_DATA') { return $false } else { throw } } }
function Read-Rows { param($d,[string]$table,[string]$where,[string[]]$fields,[int]$max)
    $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''; if ($max -gt 0) { [void]$fn.SetValue('ROWCOUNT',$max) }
    if ($where) { $line=''; foreach ($cl in ($where -split '\s+AND\s+')) { $piece = if ($line -eq '') { $cl } else { "AND $cl" }; if ($line -eq '') { $line=$piece } elseif (($line.Length+1+$piece.Length) -le 72) { $line="$line $piece" } else { Add-RfcOption $fn $line; $line=$piece } }; if ($line) { Add-RfcOption $fn $line } }
    foreach ($f in $fields) { Add-RfcField $fn $f }
    if (-not (Invoke-Rfc $fn $d)) { return }
    $fm=$fn.GetTable('FIELDS');$off=@{};$len=@{};for($x=0;$x -lt $fm.RowCount;$x++){$fm.CurrentIndex=$x;$nm=("$($fm.GetString('FIELDNAME'))").Trim();$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
    $dt=$fn.GetTable('DATA');for($x=0;$x -lt $dt.RowCount;$x++){$dt.CurrentIndex=$x;$wa="$($dt.GetString('WA'))";$rec=[ordered]@{};foreach($f in $fields){$o=$off[$f];$l=$len[$f];$rec[$f]=if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).Trim()}else{''}};[pscustomobject]$rec}
}
function Read-Rows-Or { param($d,[string]$table,[string]$keyField,[string[]]$vals,[string[]]$fields,[int]$max)
    $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''; if ($max -gt 0) { [void]$fn.SetValue('ROWCOUNT',$max) }
    $line=''
    foreach ($v in $vals) { $clause = "$keyField = '$v'"; $piece = if ($line -eq '') { $clause } else { "OR $clause" }; if ($line -eq '') { $line=$piece } elseif (($line.Length+1+$piece.Length) -le 72) { $line="$line $piece" } else { Add-RfcOption $fn $line; $line="OR $clause" } }
    if ($line) { Add-RfcOption $fn $line }
    foreach ($f in $fields) { Add-RfcField $fn $f }
    if (-not (Invoke-Rfc $fn $d)) { return }
    $fm=$fn.GetTable('FIELDS');$off=@{};$len=@{};for($x=0;$x -lt $fm.RowCount;$x++){$fm.CurrentIndex=$x;$nm=("$($fm.GetString('FIELDNAME'))").Trim();$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
    $dt=$fn.GetTable('DATA');for($x=0;$x -lt $dt.RowCount;$x++){$dt.CurrentIndex=$x;$wa="$($dt.GetString('WA'))";$rec=[ordered]@{};foreach($f in $fields){$o=$off[$f];$l=$len[$f];$rec[$f]=if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).Trim()}else{''}};[pscustomobject]$rec}
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $Objects) { Write-Host 'STATUS: RFC_ERROR reason=no_objects'; exit 2 }

$dest = $null; try { $dest = Connect-SapRfc -DestName 'RETRO_PROJ' } catch { }
if (-not $dest) { Write-Host 'STATUS: RFC_LOGON_FAILED'; exit 2 }
$SID=''; try { $si=$dest.Repository.CreateFunction('RFC_SYSTEM_INFO'); $si.Invoke($dest); $SID=(San $si.GetStructure('RFCSI_EXPORT').GetString('RFCSYSID')) } catch { }

try {
    $items = @($Objects -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $n = 0
    foreach ($it in $items) {
        $parts = $it -split ':', 2
        $otype = $parts[0].Trim().ToUpper(); $oname = if ($parts.Count -gt 1) { $parts[1].Trim().ToUpper() } else { '' }
        if (-not $oname) { continue }
        $n++

        # TADIR existence (project line)
        $tadir = 'COULD_NOT_CHECK'
        try { $td = @(Read-Rows $dest 'TADIR' "OBJECT = '$otype' AND OBJ_NAME = '$oname'" @('OBJ_NAME','DELFLAG') 2); $tadir = if ($td.Count -and (San $td[0].DELFLAG) -ne 'X') { 'EXISTS' } else { 'ABSENT' } } catch { $tadir = 'COULD_NOT_CHECK' }

        # VRSD versions since baseline (project line changed?) - keyed by OBJNAME (any version type)
        $vrsd = 'COULD_NOT_CHECK'
        try {
            $where = "OBJNAME = '$oname'"; if ($Baseline) { $where = "$where AND DATUM GE '$Baseline'" }
            $vr = @(Read-Rows $dest 'VRSD' $where @('OBJTYPE','OBJNAME','VERSNO','DATUM','KORRNUM') 500)
            $vrsd = if ($vr.Count -gt 0) { "HIT:$($vr.Count)" } else { 'CLEAN' }
        } catch { $vrsd = 'COULD_NOT_CHECK' }

        # E071 project-line TR hits since baseline (confirmed project dev change)
        $e071 = 'COULD_NOT_CHECK'
        try {
            $hits = @(Read-Rows $dest 'E071' "OBJECT = '$otype' AND OBJ_NAME = '$oname'" @('TRKORR','OBJECT','OBJ_NAME') 500)
            if ($hits.Count -eq 0) { $e071 = 'CLEAN' }
            else {
                $trk = @($hits | ForEach-Object { San $_.TRKORR } | Select-Object -Unique)
                # a project CHANGE is a workbench/customizing request (K/W) since baseline - NOT a
                # support-package (S) / transport-of-copies (T) / import, which would be a false YELLOW.
                $hitTr = ''
                for ($i=0; $i -lt $trk.Count -and -not $hitTr; $i += 40) {
                    $chunk = $trk[$i..([Math]::Min($i+39,$trk.Count-1))]
                    foreach ($e in (Read-Rows-Or $dest 'E070' 'TRKORR' $chunk @('TRKORR','AS4DATE','TRFUNCTION') 0)) {
                        $d4 = San $e.AS4DATE; $fn4 = San $e.TRFUNCTION
                        if (($fn4 -eq 'K' -or $fn4 -eq 'W') -and (-not $Baseline -or $d4 -ge $Baseline)) { $hitTr = San $e.TRKORR; break }
                    }
                }
                $e071 = if ($hitTr) { "HIT:$hitTr" } else { 'CLEAN' }
            }
        } catch { $e071 = 'COULD_NOT_CHECK' }

        Write-Host ("EVIDENCE: object={0} obj_name={1} tadir={2} vrsd={3} e071={4}" -f $otype,$oname,$tadir,$vrsd,$e071)
    }
    Write-Host ("STATUS: OK objs={0} sid={1}" -f $n,$SID)
    Disconnect-SapRfc; exit 0
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
