# =============================================================================
# sap_data_volume_rfc.ps1  -  read-only DB growth + archivability probe for /sap-data-volume
#
# Two actions, one connection, pure RFC (all FMODE=R, probed identical S4D 754 + ERP 731):
#   growth        rank tables by row count (EM_GET_NUMBER_OF_ENTRIES) + DD09L size cat,
#                 diff vs the most recent local snapshot for a rows/day trend, flag log-table
#                 offenders and Z tables that lack housekeeping.
#   archivability per archiving object: table mapping (ARCH_DEF), run history (ADMI_RUN +
#                 ADMI_STATS), and TAANA analysis presence (TAAN_HEAD). The per-bucket age
#                 distribution lives in the TAAN_DATA cluster blob (CLUSTD RAW) which
#                 RFC_READ_TABLE cannot decode -> COULD_NOT_CHECK, pointer to `analyze` (v1.5).
#
# Counts use EM_GET_NUMBER_OF_ENTRIES: TABLES IT_TABLES (TABNAME in, TABROWS out). It returns
# fast DB-statistics counts (works on CLUSTER tables too -- EDID4 6.4M / CDPOS 5.9M on ERP)
# and yields TABROWS = -1 for a non-existent/failed table -> a COUNT_FAILED row, never a fake 0.
#
#   -Action growth|archivability
#   growth:        [-Tables A,B] [-ZOnly] [-MaxTables 200] [-ZThreshold 1000000] [-OffenderFile <tsv>] [-SnapshotDir <dir>]
#   archivability: [-Object O1,O2] [-ArchTable T1,T2] [-ResidenceDays N]
#   common:        -OutDir <dir> [-SharedDir <dir>] [-RunId <id>]
#
# stdout:
#   growth:        DATAVOL: table=<t> rows=<n|COUNT_FAILED> class=<c> sizecat=<k> delta=<d|n/a> perday=<r|n/a> flag=<f>
#                  DATAVOL_FLAG: kind=<Z_TABLE_NO_HOUSEKEEPING|LOG_TABLE_LARGE> table=<t> rows=<n> severity=<HIGH|MEDIUM|LOW>
#                  DATAVOL_SNAPSHOT: <BASELINE_CREATED|DELTA> prior=<ts|none> path=<snapshot>
#   archivability: DATAVOL_ARCH: object=<o> text="<..>" tables=<n> lastrun=<date|none> runs=<n> analysis=<PRESENT|ABSENT|COULD_NOT_CHECK> entrycnt=<n|n/a>
#   both:          STATUS: OK | RFC_LOGON_FAILED | RFC_ERROR sid=<SID> client=<C>
# Writes growth.tsv / archivability.tsv (UTF-8 BOM). Exit 0/2.
# =============================================================================

[CmdletBinding()]
param(
    [ValidateSet('growth','archivability')]
    [string] $Action = 'growth',
    [string] $Tables       = '',
    [switch] $ZOnly,
    [int]    $MaxTables    = 200,
    [long]   $ZThreshold   = 1000000,
    [string] $OffenderFile = '',
    [string] $SnapshotDir  = '',
    [string] $Object       = '',
    [string] $ArchTable    = '',
    [int]    $ResidenceDays = 0,
    [string] $OutDir       = '',
    [string] $SharedDir    = '',
    [string] $RunId        = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
foreach ($lib in 'sap_connection_lib.ps1','sap_rfc_lib.ps1') { $pp = Join-Path $scripts $lib; if (Test-Path $pp) { . $pp } }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Invoke-Rfc { param($fn,$d) try { $fn.Invoke($d); return $true } catch { if ("$($_.Exception.Message)" -match 'TABLE_WITHOUT_DATA') { return $false } else { throw } } }

# Direct offset-based reader (delimiter '' + FIELDS OFFSET/LENGTH slicing) -- delimiter-proof
# and correct at scale. WHERE split at ' AND ' into <=72-char OPTIONS rows. Returns plain
# $out (NOT ,$out -- callers wrap in @() and the comma-wrap collapses to 1 under @()).
function Read-Rows { param($d,[string]$table,[string]$where,[string[]]$fields,[int]$max)
    $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''; if ($max -gt 0) { [void]$fn.SetValue('ROWCOUNT',$max) }
    if ($where) { $line=''; foreach ($cl in ($where -split '\s+AND\s+')) { $piece = if ($line -eq '') { $cl } else { "AND $cl" }; if ($line -eq '') { $line=$piece } elseif (($line.Length+1+$piece.Length) -le 72) { $line="$line $piece" } else { Add-RfcOption $fn $line; $line=$piece } }; if ($line) { Add-RfcOption $fn $line } }
    foreach ($f in $fields) { Add-RfcField $fn $f }
    if (-not (Invoke-Rfc $fn $d)) { return @() }
    $fm=$fn.GetTable('FIELDS');$off=@{};$len=@{};for($x=0;$x -lt $fm.RowCount;$x++){$fm.CurrentIndex=$x;$nm=("$($fm.GetString('FIELDNAME'))").Trim();$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
    $dt=$fn.GetTable('DATA');$out=@();for($x=0;$x -lt $dt.RowCount;$x++){$dt.CurrentIndex=$x;$wa="$($dt.GetString('WA'))";$rec=[ordered]@{};foreach($f in $fields){$o=$off[$f];$l=$len[$f];$rec[$f]=if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).Trim()}else{''}};$out+=,([pscustomobject]$rec)}
    return $out
}

# OR-chunked set read: RFC_READ_TABLE has NO SQL IN operator, so filter <keyField> in a set
# by OR'd equalities packed into <=72-char OPTIONS rows (continuation rows start with OR).
function Read-Rows-Or { param($d,[string]$table,[string]$keyField,[string[]]$vals,[string[]]$fields,[int]$max)
    $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''; if ($max -gt 0) { [void]$fn.SetValue('ROWCOUNT',$max) }
    $line=''
    foreach ($v in $vals) {
        $clause = "$keyField = '$v'"; $piece = if ($line -eq '') { $clause } else { "OR $clause" }
        if ($line -eq '') { $line=$piece } elseif (($line.Length+1+$piece.Length) -le 72) { $line="$line $piece" } else { Add-RfcOption $fn $line; $line="OR $clause" }
    }
    if ($line) { Add-RfcOption $fn $line }
    foreach ($f in $fields) { Add-RfcField $fn $f }
    if (-not (Invoke-Rfc $fn $d)) { return @() }
    $fm=$fn.GetTable('FIELDS');$off=@{};$len=@{};for($x=0;$x -lt $fm.RowCount;$x++){$fm.CurrentIndex=$x;$nm=("$($fm.GetString('FIELDNAME'))").Trim();$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
    $dt=$fn.GetTable('DATA');$out=@();for($x=0;$x -lt $dt.RowCount;$x++){$dt.CurrentIndex=$x;$wa="$($dt.GetString('WA'))";$rec=[ordered]@{};foreach($f in $fields){$o=$off[$f];$l=$len[$f];$rec[$f]=if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).Trim()}else{''}};$out+=,([pscustomobject]$rec)}
    return $out
}

# Batched row counts via EM_GET_NUMBER_OF_ENTRIES. Returns a hashtable table -> [long] rows
# (-1 preserved as the not-found/failed sentinel). Chunked so a huge scope stays one FM/chunk.
function Count-Tables { param($d,[string[]]$tabs)
    $res = @{}
    for ($i=0; $i -lt $tabs.Count; $i += 100) {
        $chunk = $tabs[$i..([Math]::Min($i+99,$tabs.Count-1))]
        $fn = $d.Repository.CreateFunction('EM_GET_NUMBER_OF_ENTRIES')
        $it = $fn.GetTable('IT_TABLES')
        foreach ($tb in $chunk) { $it.Append(); $it.SetValue('TABNAME',$tb) }
        try {
            $fn.Invoke($d)
            $itr = $fn.GetTable('IT_TABLES')
            for ($r=0; $r -lt $itr.RowCount; $r++) { $itr.CurrentIndex=$r; $nm=("$($itr.GetString('TABNAME'))").Trim(); $rc=[long]("$($itr.GetString('TABROWS'))".Trim()); $res[$nm]=$rc }
        } catch { foreach ($tb in $chunk) { if (-not $res.ContainsKey($tb)) { $res[$tb] = -1 } } }
    }
    return $res
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $OutDir) { Write-Host 'STATUS: RFC_ERROR no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$dest = $null; try { $dest = Connect-SapRfc -DestName 'DV_SWEEP' } catch { }
if (-not $dest) { Write-Host 'STATUS: RFC_LOGON_FAILED'; exit 2 }

# ---- identity: SID + release (RFC_SYSTEM_INFO), logon client (USR02 MANDT) ----
$SID=''; $REL=''; $CLIENT=''
try { $si = $dest.Repository.CreateFunction('RFC_SYSTEM_INFO'); $si.Invoke($dest); $exp=$si.GetStructure('RFCSI_EXPORT'); $SID=(San $exp.GetString('RFCSYSID')); $REL=(San $exp.GetString('RFCSAPRL')) } catch { }
try { $cr = @(Read-Rows $dest 'USR02' '' @('MANDT') 1); if ($cr.Count) { $CLIENT=(San $cr[0].MANDT) } } catch { }
$isEcc = $false; if ($REL -match '^\d+$' -and [int]$REL -lt 740) { $isEcc = $true }

function Load-Offenders { param([string]$path)
    $rows=@()
    if (-not $path -or -not (Test-Path $path)) { return $rows }
    $txt=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
    foreach ($ln in ($txt -split "`r`n|`n")) {
        if (-not $ln -or $ln.StartsWith('#')) { continue }
        $c = $ln -split "`t"; if ($c.Count -lt 1 -or -not $c[0].Trim()) { continue }
        if ($c[0].Trim() -eq 'table') { continue }
        $rows += [pscustomobject]@{ table=$c[0].Trim(); area=$(if($c.Count -gt 1){$c[1].Trim()}else{''}); header=$(if($c.Count -gt 2){$c[2].Trim()}else{''}); datefld=$(if($c.Count -gt 3){$c[3].Trim()}else{''}); arch=$(if($c.Count -gt 4){$c[4].Trim()}else{''}); cluster=$(if($c.Count -gt 5){$c[5].Trim()}else{''}); note=$(if($c.Count -gt 6){$c[6].Trim()}else{''}) }
    }
    return $rows
}

try {
    if ($Action -eq 'growth') {
        # ---- 1. build scope --------------------------------------------------
        $offenders = @(Load-Offenders $OffenderFile)
        $offMap = @{}; foreach ($o in $offenders) { $offMap[$o.table]=$o }
        $scope = New-Object System.Collections.Generic.List[string]
        $seen = @{}
        function Add-Scope { param([string]$t) $t=$t.Trim().ToUpper(); if ($t -and -not $seen.ContainsKey($t)) { $seen[$t]=$true; [void]$scope.Add($t) } }

        if ($Tables) {
            foreach ($t in ($Tables -split ',')) { Add-Scope $t }
        } else {
            if (-not $ZOnly) { foreach ($o in $offenders) { Add-Scope $o.table } }
            # Z*/Y* transparent + cluster + pool tables from DD02L (capped)
            $room = [Math]::Max(0, $MaxTables - $scope.Count)
            if ($room -gt 0) {
                $zrows = @()
                foreach ($pfx in @('Z','Y')) {
                    if ($zrows.Count -ge $room) { break }
                    $zr = @(Read-Rows $dest 'DD02L' "TABNAME LIKE '$pfx%' AND TABCLASS = 'TRANSP' AND AS4LOCAL = 'A'" @('TABNAME','TABCLASS') ([Math]::Min(5000,$room*4)))
                    $zrows += $zr
                }
                foreach ($zr in $zrows) { if ($scope.Count -ge $MaxTables) { break }; Add-Scope $zr.TABNAME }
            }
        }
        if ($scope.Count -eq 0) { Write-Host 'DATAVOL: (empty scope)'; Write-Host "STATUS: OK sid=$SID client=$CLIENT"; Disconnect-SapRfc; exit 0 }
        $scopeArr = @($scope.ToArray())
        if ($scopeArr.Count -gt $MaxTables) { $scopeArr = $scopeArr[0..($MaxTables-1)] }

        # ---- 2. existence + size category via DD02L/DD09L --------------------
        $classOf=@{}; $existSet=@{}
        # DD02L existence + TABCLASS (OR-chunked over the scope)
        $dd02 = @()
        for ($i=0;$i -lt $scopeArr.Count;$i+=50) {
            $ch=$scopeArr[$i..([Math]::Min($i+49,$scopeArr.Count-1))]
            $dd02 += @(Read-Rows-Or $dest 'DD02L' 'TABNAME' $ch @('TABNAME','TABCLASS') 0)
        }
        foreach ($r in $dd02) { $t=(San $r.TABNAME); if ($t) { $existSet[$t]=$true; $classOf[$t]=(San $r.TABCLASS) } }

        $catOf=@{}; $artOf=@{}
        $dd09 = @()
        for ($i=0;$i -lt $scopeArr.Count;$i+=50) {
            $ch=$scopeArr[$i..([Math]::Min($i+49,$scopeArr.Count-1))]
            $dd09 += @(Read-Rows-Or $dest 'DD09L' 'TABNAME' $ch @('TABNAME','TABKAT','TABART') 0)
        }
        foreach ($r in $dd09) { $t=(San $r.TABNAME); if ($t) { $catOf[$t]=(San $r.TABKAT); $artOf[$t]=(San $r.TABART) } }

        # ---- 3. counts (existing tables only) -------------------------------
        $existing = @($scopeArr | Where-Object { $existSet.ContainsKey($_) })
        $missing  = @($scopeArr | Where-Object { -not $existSet.ContainsKey($_) })
        foreach ($m in $missing) { Write-Host ("DATAVOL_SKIP: table={0} reason=not_in_DD02L" -f $m) }
        $counts = if ($existing.Count) { Count-Tables $dest $existing } else { @{} }

        # ---- 4. snapshot store + delta --------------------------------------
        $prior=$null; $priorTs='none'
        if ($SnapshotDir) {
            if (-not (Test-Path $SnapshotDir)) { New-Item -ItemType Directory -Force -Path $SnapshotDir | Out-Null }
            $prev = @(Get-ChildItem -Path $SnapshotDir -Filter 'snapshot_*.tsv' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
            if ($prev.Count) {
                $prior=@{}; $priorTs=($prev[0].BaseName -replace '^snapshot_','')
                foreach ($ln in ([IO.File]::ReadAllLines($prev[0].FullName))) { $c=$ln -split "`t"; if ($c.Count -ge 5 -and $c[0] -ne 'table') { $prior[$c[0]] = @{ rows=$c[3]; ts=$c[4] } } }
            }
        }
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

        # ---- 5. rows + delta + flags ----------------------------------------
        $rowsOut = New-Object System.Collections.Generic.List[object]
        foreach ($t in $existing) {
            $rc = if ($counts.ContainsKey($t)) { [long]$counts[$t] } else { -1 }
            $rcStr = if ($rc -lt 0) { 'COUNT_FAILED' } else { "$rc" }
            $cls = if ($classOf.ContainsKey($t)) { $classOf[$t] } else { '' }
            $cat = if ($catOf.ContainsKey($t)) { $catOf[$t] } else { '' }
            $art = if ($artOf.ContainsKey($t)) { $artOf[$t] } else { '' }
            $delta='n/a'; $perday='n/a'
            if ($prior -and $prior.ContainsKey($t) -and $rc -ge 0) {
                $pr=[long]$prior[$t].rows; $pts=[long]$prior[$t].ts
                $delta = "$($rc - $pr)"
                $days = [Math]::Max(1.0, ($nowSec - $pts)/86400.0)
                $perday = "{0:N1}" -f (($rc - $pr)/$days)
            }
            $rowsOut.Add([pscustomobject]@{ table=$t; rows=$rc; rowsStr=$rcStr; class=$cls; cat=$cat; art=$art; delta=$delta; perday=$perday; ts=$nowSec })
        }
        # rank by rows desc for the emit
        $ranked = @($rowsOut | Sort-Object -Property @{Expression={ if ($_.rows -lt 0) { -1 } else { $_.rows } }; Descending=$true})

        # write snapshot (all counted rows)
        $snapPath=''
        if ($SnapshotDir) {
            $sb=New-Object System.Text.StringBuilder; [void]$sb.AppendLine("table`tclass`tsizecat`trows`tts")
            foreach ($r in $ranked) { if ($r.rows -ge 0) { [void]$sb.AppendLine(("{0}`t{1}`t{2}`t{3}`t{4}" -f $r.table,$r.class,$r.cat,$r.rows,$r.ts)) } }
            $snapPath=Join-Path $SnapshotDir ("snapshot_{0}.tsv" -f $stamp)
            [IO.File]::WriteAllText($snapPath, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
        }
        if ($prior) { Write-Host ("DATAVOL_SNAPSHOT: DELTA prior={0} path={1}" -f $priorTs,$snapPath) }
        else { Write-Host ("DATAVOL_SNAPSHOT: BASELINE_CREATED prior=none path={0}" -f $snapPath) }

        # flags: Z table over threshold with no archiving mapping + positive growth; large log offender
        $flags = New-Object System.Collections.Generic.List[object]
        # which scope tables have an archiving mapping? (ARCH_DEF SON/STRUCTURE/FATHER contains the table)
        $archMapped=@{}
        try {
            foreach ($t in $existing) {
                if ($t -match '^(Z|Y)' -and $counts[$t] -ge $ZThreshold) {
                    $am = @(Read-Rows $dest 'ARCH_DEF' "SON = '$t'" @('OBJECT') 1)
                    if ($am.Count) { $archMapped[$t]=$true }
                }
            }
        } catch { }
        foreach ($r in $ranked) {
            $isZ = $r.table -match '^(Z|Y)'
            if ($isZ -and $r.rows -ge $ZThreshold -and -not $archMapped.ContainsKey($r.table)) {
                $growPos = ($r.perday -ne 'n/a' -and [double]($r.perday) -gt 0) -or ($r.perday -eq 'n/a')
                $sev = if ($r.rows -ge ($ZThreshold*10)) { 'HIGH' } else { 'MEDIUM' }
                $flags.Add([pscustomobject]@{ kind='Z_TABLE_NO_HOUSEKEEPING'; table=$r.table; rows=$r.rows; severity=$sev })
                Write-Host ("DATAVOL_FLAG: kind=Z_TABLE_NO_HOUSEKEEPING table={0} rows={1} severity={2}" -f $r.table,$r.rows,$sev)
            }
            if ($offMap.ContainsKey($r.table) -and $r.rows -ge ($ZThreshold*5)) {
                $flags.Add([pscustomobject]@{ kind='LOG_TABLE_LARGE'; table=$r.table; rows=$r.rows; severity='MEDIUM' })
                Write-Host ("DATAVOL_FLAG: kind=LOG_TABLE_LARGE table={0} rows={1} severity=MEDIUM" -f $r.table,$r.rows)
            }
        }

        # emit + write growth.tsv
        $sb=New-Object System.Text.StringBuilder; [void]$sb.AppendLine("table`trows`tclass`tsizecat`tdataclass`tdelta`tper_day`toffender_area`tecc_cluster")
        foreach ($r in $ranked) {
            $oa = if ($offMap.ContainsKey($r.table)) { $offMap[$r.table].area } else { '' }
            $ec = if ($offMap.ContainsKey($r.table) -and $isEcc) { $offMap[$r.table].cluster } else { '' }
            Write-Host ("DATAVOL: table={0} rows={1} class={2} sizecat={3} delta={4} perday={5} flag={6}" -f $r.table,$r.rowsStr,$r.class,$r.cat,$r.delta,$r.perday,$(if($oa){$oa}else{'-'}))
            [void]$sb.AppendLine(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}" -f $r.table,$r.rowsStr,$r.class,$r.cat,$r.art,$r.delta,$r.perday,$oa,$ec))
        }
        [IO.File]::WriteAllText((Join-Path $OutDir 'growth.tsv'), $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
        $failN = @($ranked | Where-Object { $_.rows -lt 0 }).Count
        Write-Host ("STATUS: OK sid=$SID client=$CLIENT release=$REL scope=$($scopeArr.Count) counted=$($existing.Count - $failN) failed=$failN missing=$($missing.Count) flags=$($flags.Count)")
        Disconnect-SapRfc; exit 0
    }
    else {
        # =================== archivability ===================================
        $logonLang = 'E'
        $objs = New-Object System.Collections.Generic.List[string]
        if ($Object) { foreach ($o in ($Object -split ',')) { if ($o.Trim()) { [void]$objs.Add($o.Trim().ToUpper()) } } }
        if ($ArchTable) {
            foreach ($tb in ($ArchTable -split ',')) {
                $tb=$tb.Trim().ToUpper(); if (-not $tb) { continue }
                $hits = @(Read-Rows $dest 'ARCH_DEF' "SON = '$tb'" @('OBJECT') 50) + @(Read-Rows $dest 'ARCH_DEF' "STRUCTURE = '$tb'" @('OBJECT') 50)
                foreach ($h in $hits) { $ob=(San $h.OBJECT); if ($ob -and -not $objs.Contains($ob)) { [void]$objs.Add($ob) } }
                if (-not $hits.Count) { Write-Host ("DATAVOL_SKIP: table={0} reason=no_ARCH_DEF_mapping" -f $tb) }
            }
        }
        if ($objs.Count -eq 0 -and -not $Object -and -not $ArchTable) {
            # default: objects that have run history
            $ar = @(Read-Rows $dest 'ADMI_RUN' '' @('OBJECT') 2000)
            $distinct = @($ar | ForEach-Object { (San $_.OBJECT) } | Where-Object { $_ } | Select-Object -Unique)
            foreach ($o in ($distinct | Select-Object -First 30)) { [void]$objs.Add($o) }
        }
        if ($objs.Count -eq 0) { Write-Host 'DATAVOL_ARCH: (no objects resolved)'; Write-Host "STATUS: OK sid=$SID client=$CLIENT"; Disconnect-SapRfc; exit 0 }

        $sb=New-Object System.Text.StringBuilder; [void]$sb.AppendLine("object`ttext`ttables`tlast_run`truns`tlast_status`tanalysis`tentry_cnt`tresidence_days`tage_pct")
        foreach ($ob in $objs) {
            # text
            $txtRows = @(Read-Rows $dest 'ARCH_TXT' "OBJECT = '$ob' AND LANGU = '$logonLang'" @('OBJTEXT') 1)
            if (-not $txtRows.Count) { $txtRows = @(Read-Rows $dest 'ARCH_TXT' "OBJECT = '$ob'" @('OBJTEXT') 1) }
            $otext = if ($txtRows.Count) { San $txtRows[0].OBJTEXT } else { '' }
            # tables = distinct SON + STRUCTURE for object (physical tables; skip blanks/structures heuristically kept)
            $defRows = @(Read-Rows $dest 'ARCH_DEF' "OBJECT = '$ob'" @('SON','STRUCTURE') 500)
            $tabset=@{}; foreach ($dr in $defRows) { foreach ($v in @((San $dr.SON),(San $dr.STRUCTURE))) { if ($v) { $tabset[$v]=$true } } }
            $tabList = @($tabset.Keys | Sort-Object)
            # run history
            $runRows = @(Read-Rows $dest 'ADMI_RUN' "OBJECT = '$ob'" @('DOCUMENT','CREAT_DATE','STATUS') 2000)
            $runN = $runRows.Count
            $lastRun='none'; $lastStat=''
            if ($runN) { $sorted=@($runRows | Sort-Object { $_.CREAT_DATE } -Descending); $lastRun=(San $sorted[0].CREAT_DATE); $lastStat=(San $sorted[0].STATUS) }
            # TAANA analysis presence for any of the object's tables
            $analysis='ABSENT'; $entryCnt='n/a'
            if ($tabList.Count) {
                foreach ($tb in ($tabList | Select-Object -First 20)) {
                    $th = @(Read-Rows $dest 'TAAN_HEAD' "TABNAME = '$tb'" @('ENTRY_CNT','EVAL_STAT','STOP_DATE') 5)
                    if ($th.Count) { $analysis='PRESENT'; $best=@($th | Sort-Object { $_.STOP_DATE } -Descending)[0]; $entryCnt=(San $best.ENTRY_CNT); break }
                }
            }
            # age % lives in the TAAN_DATA cluster blob (CLUSTD RAW) -> not decodable via RFC_READ_TABLE
            $agePct = if ($analysis -eq 'PRESENT') { 'COULD_NOT_CHECK' } else { 'n/a' }
            $resid = if ($ResidenceDays -gt 0) { "$ResidenceDays" } else { 'n/a' }
            Write-Host ("DATAVOL_ARCH: object={0} text=`"{1}`" tables={2} lastrun={3} runs={4} analysis={5} entrycnt={6}" -f $ob,($otext -replace '"',"'"),$tabList.Count,$lastRun,$runN,$analysis,$entryCnt)
            [void]$sb.AppendLine(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}`t{9}" -f $ob,$otext,($tabList -join ','),$lastRun,$runN,$lastStat,$analysis,$entryCnt,$resid,$agePct))
        }
        [IO.File]::WriteAllText((Join-Path $OutDir 'archivability.tsv'), $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
        Write-Host ("STATUS: OK sid=$SID client=$CLIENT release=$REL objects=$($objs.Count)")
        Disconnect-SapRfc; exit 0
    }
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
