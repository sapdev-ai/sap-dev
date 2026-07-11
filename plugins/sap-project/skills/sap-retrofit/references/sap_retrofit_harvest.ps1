# =============================================================================
# sap_retrofit_harvest.ps1  -  read released maintenance-line TRs for /sap-retrofit (read-only)
#
# Connects the MAINTENANCE profile (-MaintHint, resolved like /sap-compare --against) and reads
# released workbench/customizing TRs since the watermark, expands to per-object rows, and
# applies the optional package filter via a maintenance-side TADIR DEVCLASS join. Pure RFC
# (E070/E07T/E071/TADIR all FMODE=R / TRANSP on both releases). The maintenance system is
# read-only forever - this script never writes.
#
#   -MaintHint <hint> [-Since <YYYYMMDD>] [-Packages <Z*,Y*>] [-MaxTrs N] [-Workbench-only] [-SharedDir <dir>] [-RunId <id>]
#
# stdout: TR: trkorr=<t> func=<K|W> date=<d> desc="<..>"
#         OBJ: pgmid=<R3TR|LIMU> object=<type> obj_name=<n> tr=<t> released=<d> devclass=<c>
#         STATUS: OK trs=<n> objs=<n> | NO_NEW | RFC_LOGON_FAILED | RFC_ERROR  ; exit 0/2
# =============================================================================
[CmdletBinding()]
param(
    [string] $MaintHint = '',
    [string] $Since     = '',
    [string] $Packages  = '',
    [int]    $MaxTrs    = 500,
    [switch] $WorkbenchOnly,
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
# OR-chunked set read (RFC_READ_TABLE has no IN operator)
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
function Match-Pkg { param([string]$devclass,[string[]]$pats)
    if (-not $pats -or $pats.Count -eq 0) { return $true }
    foreach ($p in $pats) {
        $rx = '^' + [regex]::Escape($p).Replace('\*','.*') + '$'
        if ($devclass -match $rx) { return $true }
    }
    return $false
}

if ($MyInvocation.InvocationName -eq '.') { return }

$dest = $null
try {
    $cands = @(Resolve-SapProfileHint -Hint $MaintHint)
    if ($cands.Count -ne 1) { Write-Host ("STATUS: RFC_LOGON_FAILED reason=maint_profile_{0}_resolves_to_{1}" -f $MaintHint,$cands.Count); exit 2 }
    $t = $cands[0]
    $pw = (& (Join-Path $scripts 'sap_dpapi.ps1') -Action unprotect -Value "$($t.password_dpapi)" 2>$null) -as [string]
    $dest = Connect-SapRfc -Server $t.application_server -Sysnr $t.system_number -MessageServer $t.message_server -LogonGroup $t.logon_group -SystemID $t.system_id -Client $t.client -User $t.user -Password $pw -Language $t.language -DestName 'RETRO_MAINT'
} catch { }
if (-not $dest) { Write-Host 'STATUS: RFC_LOGON_FAILED'; exit 2 }

try {
    $pkgPats = @(); if ($Packages) { $pkgPats = @($Packages -split ',' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ }) }
    # 1. released TRs since watermark
    $where = "TRSTATUS = 'R'"; if ($Since) { $where = "$where AND AS4DATE GE '$Since'" }
    $trs = @(Read-Rows $dest 'E070' $where @('TRKORR','TRFUNCTION','TRSTATUS','AS4DATE','AS4TIME') 20000)
    # keep only workbench (K) and, unless -WorkbenchOnly, customizing (W); order by date+time
    $keepFn = if ($WorkbenchOnly) { @('K') } else { @('K','W') }
    $trs = @($trs | Where-Object { $keepFn -contains (San $_.TRFUNCTION) } | Sort-Object { "$($_.AS4DATE)$($_.AS4TIME)" })
    if ($trs.Count -gt $MaxTrs) { $trs = @($trs | Select-Object -Last $MaxTrs) }
    if ($trs.Count -eq 0) { Write-Host 'STATUS: NO_NEW'; Disconnect-SapRfc; exit 0 }

    # 2. descriptions (E07T, EN preferred)
    $trList = @($trs | ForEach-Object { San $_.TRKORR })
    $texts = @{}
    for ($i=0; $i -lt $trList.Count; $i += 40) {
        $chunk = $trList[$i..([Math]::Min($i+39,$trList.Count-1))]
        foreach ($tt in (Read-Rows-Or $dest 'E07T' 'TRKORR' $chunk @('TRKORR','AS4TEXT','LANGU') 0)) {
            $k = San $tt.TRKORR; if (-not $texts.ContainsKey($k) -or (San $tt.LANGU) -eq 'E') { $texts[$k] = San $tt.AS4TEXT }
        }
    }
    foreach ($tr in $trs) { $k=San $tr.TRKORR; Write-Host ("TR: trkorr={0} func={1} date={2} desc=`"{3}`"" -f $k,(San $tr.TRFUNCTION),(San $tr.AS4DATE),(($texts[$k]) -replace '"',"'")) }

    # 3. objects per TR (E071); collect distinct objects with their latest TR
    $objMap = @{}   # key object|obj_name -> record
    for ($i=0; $i -lt $trList.Count; $i += 40) {
        $chunk = $trList[$i..([Math]::Min($i+39,$trList.Count-1))]
        foreach ($o in (Read-Rows-Or $dest 'E071' 'TRKORR' $chunk @('TRKORR','PGMID','OBJECT','OBJ_NAME') 0)) {
            $pg = San $o.PGMID; $ot = San $o.OBJECT; $on = San $o.OBJ_NAME
            if (-not $on -or $ot -in @('','RELE','CORR','MERG')) { continue }
            $key = "$ot|$on"
            $trk = San $o.TRKORR
            $date = ($trs | Where-Object { (San $_.TRKORR) -eq $trk } | Select-Object -First 1).AS4DATE
            if (-not $objMap.ContainsKey($key)) { $objMap[$key] = [ordered]@{ pgmid=$pg; object=$ot; obj_name=$on; trs=@($trk); latest=$trk; date=(San $date) } }
            else { if ($objMap[$key].trs -notcontains $trk) { $objMap[$key].trs += $trk }; $objMap[$key].latest = $trk; $objMap[$key].date = (San $date) }
        }
    }

    # 4. package filter via TADIR DEVCLASS (maintenance side)
    $devOf = @{}
    if ($pkgPats.Count -gt 0) {
        $names = @($objMap.Values | ForEach-Object { $_.obj_name } | Select-Object -Unique)
        for ($i=0; $i -lt $names.Count; $i += 40) {
            $chunk = $names[$i..([Math]::Min($i+39,$names.Count-1))]
            foreach ($td in (Read-Rows-Or $dest 'TADIR' 'OBJ_NAME' $chunk @('OBJECT','OBJ_NAME','DEVCLASS') 0)) {
                $devOf["$(San $td.OBJECT)|$(San $td.OBJ_NAME)"] = San $td.DEVCLASS
            }
        }
    }

    $emitted = 0
    foreach ($key in $objMap.Keys) {
        $r = $objMap[$key]
        $dev = if ($devOf.ContainsKey($key)) { $devOf[$key] } else { '' }
        if ($pkgPats.Count -gt 0 -and -not (Match-Pkg $dev $pkgPats)) { continue }
        $emitted++
        Write-Host ("OBJ: pgmid={0} object={1} obj_name={2} tr={3} released={4} devclass={5}" -f $r.pgmid,$r.object,$r.obj_name,$r.latest,$r.date,$dev)
    }
    Write-Host ("STATUS: OK trs={0} objs={1}" -f $trs.Count,$emitted)
    Disconnect-SapRfc; exit 0
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
