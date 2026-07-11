# =============================================================================
# sap_config_compare_read.ps1  -  dual-system customizing reader for /sap-config-compare
#
# Connects LEFT (pinned profile) + RIGHT (--against profile hint) over pure RFC,
# resolves ONE table/view on both, computes the compared-field set (intersection
# minus MANDT/CLNT, minus STRG/RSTR, minus fields too wide to chunk), guards
# against an unbounded read, then does a CHUNKED offset-based read of each side and
# writes left.tsv / right.tsv (identical column order) + meta.json + texts.tsv for
# the offline keyed-diff to consume. READ-ONLY (RFC_READ_TABLE + DDIF_FIELDINFO_GET
# only; both FMODE=R, probed identical S4D + EC2 2026-07-11).
#
#   -Object <TABLE|VIEW> -Against <profile-hint> [-Where "F=V,F=A..B"] [-Options "<raw>"]
#   [-Fields F1,F2] [-KeysOnly] [-MaxRows N] -OutDir <dir>
#
# Identity per side is read LIVE (RFC_SYSTEM_INFO->SID, USR02 MANDT->logon client) --
# NOT from the profile store, which can be stale for the pinned connection. LEFT==RIGHT
# (same SID+client) is refused.
#
# Offset parse: New-RfcReadTable -Delimiter '' packs fields fixed-width; each field is
# sliced by its FIELDS-table OFFSET/LENGTH, so a field value containing any delimiter
# char can never corrupt the parse (the plan's hard requirement).
#
# stdout (parseable by SKILL.md):
#   IDENT: side=<L|R> sid=<..> client=<..> release=<..>
#   OBJECT: kind=<TABLE|VIEW_DB|VIEW_MAINT_BASE> read_target=<tbl> [note=..]
#   FIELDS: keys=<n> compared=<n> excluded=<n> only_left=<n> only_right=<n>
#   READ: side=<L|R> rows=<n> capped=<Y|N> groups=<g>
#   STATUS: OK | CFG_OBJECT_NOT_FOUND | CFG_NO_COMMON_KEY | CFG_UNBOUNDED_READ
#           | CFG_SAME_IDENTITY | RFC_LOGON_FAILED | RFC_ERROR   <detail>
# Exit: 0 OK | 1 refusal (object/key/unbounded/identity) | 2 connect/RFC failure.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Object   = '',
    [string] $Against  = '',
    [string] $Where    = '',
    [string] $Options  = '',
    [string] $Fields   = '',
    [switch] $KeysOnly,
    [int]    $MaxRows   = 10000,
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

$MAXCEIL = 100000
if ($MaxRows -le 0) { $MaxRows = 10000 }
if ($MaxRows -gt $MAXCEIL) { $MaxRows = $MAXCEIL }
$effMax = if ($KeysOnly) { [Math]::Min($MaxRows * 5, $MAXCEIL) } else { $MaxRows }

function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function JEsc { param([string]$s) return (("$s") -replace '\\','\\' -replace '"','\"' -replace "`t",' ' -replace "`r",' ' -replace "`n",' ') }
function Write-Tsv { param([string]$Path,[string]$Header,[object[]]$Lines)
    $sb = New-Object System.Text.StringBuilder; [void]$sb.AppendLine($Header)
    foreach ($l in $Lines) { [void]$sb.AppendLine($l) }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}

# Append a WHERE string to an RFC_READ_TABLE call as OPTIONS rows, split at ' AND '
# boundaries so no row exceeds the 72-char OPTIONS-TEXT limit (self-contained -- the
# reader depends only on rfc/connection libs, not sap_object_resolver).
function Add-WhereChunked { param($fn,[string]$where)
    if (-not $where) { return }
    $clauses = $where -split '\s+AND\s+'
    $line = ''
    for ($i=0; $i -lt $clauses.Count; $i++) {
        $piece = if ($i -eq 0) { $clauses[$i] } else { 'AND ' + $clauses[$i] }
        if ($line -eq '') { $line = $piece }
        elseif (($line.Length + 1 + $piece.Length) -le 72) { $line = "$line $piece" }
        else { Add-RfcOption $fn $line; $line = $piece }
    }
    if ($line) { Add-RfcOption $fn $line }
}

# RFC_READ_TABLE raises TABLE_WITHOUT_DATA (exception) for an empty selection on some
# kernels (observed on the ERP/731 kernel). An empty result is valid, never an error.
# Returns $true if rows may be present, $false if the selection was provably empty.
function Invoke-Rfc { param($fn,$d)
    try { $fn.Invoke($d); return $true }
    catch { if ("$($_.Exception.Message)" -match 'TABLE_WITHOUT_DATA') { return $false } else { throw } }
}

# ---- live identity: SID via RFC_SYSTEM_INFO, logon client via USR02 MANDT -----
function Get-SidRelease { param($d)
    try { $fn = $d.Repository.CreateFunction('RFC_SYSTEM_INFO'); $fn.Invoke($d); $si = $fn.GetStructure('RFCSI_EXPORT')
          return @{ sid = (San $si.GetValue('RFCSYSID')); release = (San $si.GetValue('RFCSAPRL')) } }
    catch { return @{ sid = ''; release = '' } }
}
function Get-LogonClient { param($d)
    try { $fn = New-RfcReadTable -Destination $d -Table 'USR02' -Delimiter ''; [void]$fn.SetValue('ROWCOUNT',1); Add-RfcField $fn 'MANDT'; $fn.Invoke($d)
          $fm = $fn.GetTable('FIELDS'); if ($fm.RowCount -lt 1) { return '' }; $fm.CurrentIndex=0; $o=[int]$fm.GetString('OFFSET'); $l=[int]$fm.GetString('LENGTH')
          $dt = $fn.GetTable('DATA'); if ($dt.RowCount -lt 1) { return '' }; $dt.CurrentIndex=0; $wa="$($dt.GetString('WA'))"
          if ($o -ge $wa.Length) { return '' }; return $wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).Trim() }
    catch { return '' }
}

# ---- DDIF_FIELDINFO_GET -> field metadata list -------------------------------
function Get-FieldInfo { param($d,[string]$tab)
    $out = @()
    try {
        $fn = $d.Repository.CreateFunction('DDIF_FIELDINFO_GET')
        $fn.SetValue('TABNAME', $tab); $fn.SetValue('LANGU','E'); $fn.SetValue('ALL_TYPES','X')
        $fn.Invoke($d)
        $dt = $fn.GetTable('DFIES_TAB')
        for ($i=0; $i -lt $dt.RowCount; $i++) { $dt.CurrentIndex=$i
            $out += ,([pscustomobject]@{
                field    = (San $dt.GetString('FIELDNAME'))
                key      = ((San $dt.GetString('KEYFLAG')) -eq 'X')
                datatype = (San $dt.GetString('DATATYPE'))
                leng     = [int]("0"+(San $dt.GetString('LENG')))
                outlen   = [int]("0"+(San $dt.GetString('OUTPUTLEN')))
                decimals = [int]("0"+(San $dt.GetString('DECIMALS')))
                rollname = (San $dt.GetString('ROLLNAME'))
                position = [int]("0"+(San $dt.GetString('POSITION')))
            })
        }
    } catch { return @() }
    return $out
}

# ---- object resolution: DD02L (table) then DD25L (view) ----------------------
function Read-One { param($d,[string]$tab,[string]$where,[string[]]$flds)
    $fn = New-RfcReadTable -Destination $d -Table $tab -Delimiter ''
    [void]$fn.SetValue('ROWCOUNT',1); Add-RfcOption $fn $where
    foreach ($f in $flds) { Add-RfcField $fn $f }
    if (-not (Invoke-Rfc $fn $d)) { return $null }
    $fm = $fn.GetTable('FIELDS'); $off=@{}; $len=@{}
    for ($i=0;$i -lt $fm.RowCount;$i++){$fm.CurrentIndex=$i;$nm=(San $fm.GetString('FIELDNAME'));$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
    $dt = $fn.GetTable('DATA'); if ($dt.RowCount -lt 1) { return $null }
    $dt.CurrentIndex=0; $wa="$($dt.GetString('WA'))"; $rec=@{}
    foreach ($f in $flds){ $o=$off[$f];$l=$len[$f]; $rec[$f]= if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).Trim()}else{''} }
    return $rec
}
function Resolve-Object { param($d,[string]$obj)
    # A real table (TABCLASS TRANSP/POOL/CLUSTER) reads directly. A DD02L entry with
    # TABCLASS='VIEW' can be a DATABASE/PROJECTION view (RFC_READ_TABLE reads it) OR a
    # MAINTENANCE/HELP view (screen construct, no DB projection -> RFC_READ_TABLE returns
    # 0 rows). DD25L VIEWCLASS is the discriminator: D/P read directly; C/H decompose to
    # base tables via DD26S.
    $tb = Read-One $d 'DD02L' "TABNAME = '$obj'" @('TABNAME','TABCLASS','CONTFLAG','CLIDEP')
    if ($tb -and $tb['TABCLASS'] -ne 'VIEW') {
        return @{ kind='TABLE'; read_target=$obj; tabclass=$tb['TABCLASS']; contflag=$tb['CONTFLAG']; clidep=$tb['CLIDEP']; note='' }
    }
    $vw = Read-One $d 'DD25L' "VIEWNAME = '$obj'" @('VIEWNAME','VIEWCLASS','AGGTYPE')
    if ($vw) {
        $vc = $vw['VIEWCLASS']
        if ($vc -eq 'D' -or $vc -eq 'P') { return @{ kind='VIEW_DB'; read_target=$obj; tabclass='VIEW'; contflag=''; clidep=$(if($tb){$tb['CLIDEP']}else{''}); note="$vc view read directly via RFC_READ_TABLE" } }
        # maintenance/help view (C/H): resolve base tables via DD26S (TABPOS order)
        $bases = @()
        try { $fn = New-RfcReadTable -Destination $d -Table 'DD26S' -Delimiter ''; Add-RfcOption $fn "VIEWNAME = '$obj'"; Add-RfcField $fn 'TABNAME'; Add-RfcField $fn 'TABPOS'; $fn.Invoke($d)
              $fm=$fn.GetTable('FIELDS');$off=@{};$len=@{};for($i=0;$i -lt $fm.RowCount;$i++){$fm.CurrentIndex=$i;$nm=(San $fm.GetString('FIELDNAME'));$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
              $dt=$fn.GetTable('DATA'); for($i=0;$i -lt $dt.RowCount;$i++){$dt.CurrentIndex=$i;$wa="$($dt.GetString('WA'))"; $tn=$wa.Substring($off['TABNAME'],[Math]::Min($len['TABNAME'],$wa.Length-$off['TABNAME'])).Trim(); $tp=$wa.Substring($off['TABPOS'],[Math]::Min($len['TABPOS'],$wa.Length-$off['TABPOS'])).Trim(); if($tn){$bases+=,([pscustomobject]@{tab=$tn;pos=[int]("0"+$tp)})} } } catch { }
        if ($bases.Count -ge 1) {
            $primary = ($bases | Sort-Object pos)[0].tab
            $others  = @($bases | Sort-Object pos | Select-Object -Skip 1 | ForEach-Object { $_.tab })
            $nt = "maintenance view $obj -> base table $primary; DD28S selection conditions NOT applied in v1"
            if ($others.Count) { $nt += "; other base tables NOT diffed: " + ($others -join ',') }
            return @{ kind='VIEW_MAINT_BASE'; read_target=$primary; tabclass='TABLE'; contflag=''; clidep=''; note=$nt; other_bases=$others }
        }
        return @{ kind='VIEW_UNRESOLVED'; read_target=''; note="view $obj has no resolvable base table" }
    }
    # DD02L said VIEW but DD25L has no row (unusual) -> best-effort direct read
    if ($tb) { return @{ kind='VIEW_DB'; read_target=$obj; tabclass='VIEW'; contflag=''; clidep=$tb['CLIDEP']; note='view read directly (no DD25L class)' } }
    return $null
}

# ---- WHERE builder: -Where "F=V,F=A..B" -> OPTIONS predicate ------------------
function Build-Where { param([string]$w,[string]$raw)
    if ($raw) { return $raw }   # escape hatch (validated by caller)
    if (-not $w) { return '' }
    $parts = @()
    foreach ($term in ($w -split ',')) {
        $t = $term.Trim(); if (-not $t) { continue }
        if ($t -match '^\s*([A-Za-z0-9_/]+)\s*=\s*(.+?)\.\.(.+?)\s*$') { $parts += ("{0} BETWEEN '{1}' AND '{2}'" -f $matches[1].ToUpper(),$matches[2].Trim(),$matches[3].Trim()) }
        elseif ($t -match '^\s*([A-Za-z0-9_/]+)\s*=\s*(.+?)\s*$')     { $parts += ("{0} = '{1}'" -f $matches[1].ToUpper(),$matches[2].Trim()) }
    }
    return ($parts -join ' AND ')
}

# ---- numeric normalization by DECIMALS (notation-independent equality) --------
function Norm-Num { param([string]$v,[int]$dec)
    $s = ("$v").Trim(); if (-not $s) { return '' }
    $neg = $false
    if ($s.EndsWith('-')) { $neg=$true; $s=$s.Substring(0,$s.Length-1).Trim() }
    elseif ($s.StartsWith('-')) { $neg=$true; $s=$s.Substring(1) }
    $digits = ($s -replace '[^0-9]','')
    if (-not $digits) { return $v.Trim() }
    $digits = $digits.TrimStart('0'); if ($digits -eq '') { $digits='0' }
    if ($dec -gt 0) {
        while ($digits.Length -le $dec) { $digits = '0'+$digits }
        $ip = $digits.Substring(0,$digits.Length-$dec); $fp = $digits.Substring($digits.Length-$dec)
        $res = "$ip.$fp"
    } else { $res = $digits }
    if ($neg -and $res -ne '0') { $res = "-$res" }
    return $res
}

# ---- chunked offset read -> ordered rows keyed on concatenated PK -------------
$RS = [char]0x241E
function Read-Chunked { param($d,[string]$tab,[string]$where,$keyFlds,$valFlds,[int]$cap)
    # pack value fields into groups s.t. keyWidth + Sum(group outlen) <= 512
    $keyW = ($keyFlds | Measure-Object outlen -Sum).Sum; if (-not $keyW) { $keyW = 0 }
    $budget = 512 - [int]$keyW
    $groups = @(); $cur = @(); $curW = 0
    foreach ($vf in $valFlds) {
        $w = [int]$vf.outlen
        if ($curW + $w -gt $budget -and $cur.Count -gt 0) { $groups += ,$cur; $cur=@(); $curW=0 }
        $cur += ,$vf; $curW += $w
    }
    if ($cur.Count) { $groups += ,$cur }
    if ($groups.Count -eq 0) { $groups = @(,@()) }   # keys-only

    $master = [ordered]@{}; $capped = $false; $order = @()
    $gi = 0
    foreach ($grp in $groups) {
        $gi++
        $fn = New-RfcReadTable -Destination $d -Table $tab -Delimiter ''
        [void]$fn.SetValue('ROWCOUNT', $cap)
        if ($where) { Add-WhereChunked $fn $where }
        $readFlds = @($keyFlds) + @($grp)
        foreach ($f in $readFlds) { Add-RfcField $fn $f.field }
        if (-not (Invoke-Rfc $fn $d)) { continue }   # empty selection for this group -> 0 rows
        $fm = $fn.GetTable('FIELDS'); $off=@{}; $len=@{}
        for ($i=0;$i -lt $fm.RowCount;$i++){$fm.CurrentIndex=$i;$nm=(San $fm.GetString('FIELDNAME'));$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
        $dt = $fn.GetTable('DATA')
        if ($dt.RowCount -ge $cap) { $capped = $true }
        for ($i=0;$i -lt $dt.RowCount;$i++){
            $dt.CurrentIndex=$i; $wa="$($dt.GetString('WA'))"
            $kv = @(); foreach ($kf in $keyFlds){ $o=$off[$kf.field];$l=$len[$kf.field]; $kv += $(if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).TrimEnd()}else{''}) }
            $kstr = ($kv -join $RS)
            if (-not $master.Contains($kstr)) { $rec=[ordered]@{}; for($j=0;$j -lt $keyFlds.Count;$j++){$rec[$keyFlds[$j].field]=$kv[$j]}; $master[$kstr]=$rec; $order += $kstr }
            $rec = $master[$kstr]
            foreach ($vf in $grp){ $o=$off[$vf.field];$l=$len[$vf.field]; $raw= if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).TrimEnd()}else{''}
                $val = if ($vf.datatype -in @('DEC','CURR','QUAN')) { Norm-Num $raw $vf.decimals } else { $raw }
                $rec[$vf.field] = $val
            }
        }
    }
    return @{ rows=$master; order=$order; capped=$capped; groups=$groups.Count }
}

# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {

    if (-not $Object)  { Write-Host 'STATUS: RFC_ERROR no_object'; exit 2 }
    if (-not $Against) { Write-Host 'STATUS: RFC_ERROR no_against'; exit 2 }
    if (-not $OutDir)  { Write-Host 'STATUS: RFC_ERROR no_outdir'; exit 2 }
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $obj = $Object.ToUpper()

    # raw -Options read-only guard
    if ($Options -and ($Options -match ';' -or $Options -match '(?i)\b(INSERT|UPDATE|DELETE|MODIFY|DROP|CREATE|ALTER)\b')) {
        Write-Host 'STATUS: RFC_ERROR options_not_read_only'; exit 2
    }

    # ---- connect both --------------------------------------------------------
    $left = $null; $right = $null
    try { $left = Connect-SapRfc -DestName 'CFG_LEFT' } catch { }
    if (-not $left) { Write-Host 'STATUS: RFC_LOGON_FAILED left=pinned'; exit 2 }
    $cands = @(Resolve-SapProfileHint -Hint $Against)
    if ($cands.Count -eq 0) { Write-Host "STATUS: RFC_LOGON_FAILED against_not_found=$Against"; Disconnect-SapRfc; exit 2 }
    if ($cands.Count -gt 1) { Write-Host "STATUS: RFC_LOGON_FAILED against_ambiguous=$Against"; Disconnect-SapRfc; exit 2 }
    $t = $cands[0]
    $pw = (& (Join-Path $scripts 'sap_dpapi.ps1') -Action unprotect -Value "$($t.password_dpapi)" 2>$null) -as [string]
    try { $right = Connect-SapRfc -Server $t.application_server -Sysnr $t.system_number -MessageServer $t.message_server -LogonGroup $t.logon_group -SystemID $t.system_id -Client $t.client -User $t.user -Password $pw -Language $t.language -DestName 'CFG_RIGHT' } catch { }
    if (-not $right) { Write-Host "STATUS: RFC_LOGON_FAILED right=$Against"; Disconnect-SapRfc; exit 2 }

    try {
        # ---- identity --------------------------------------------------------
        $li = Get-SidRelease $left;  $lc = Get-LogonClient $left
        $ri = Get-SidRelease $right; $rc = Get-LogonClient $right
        Write-Host ("IDENT: side=L sid={0} client={1} release={2}" -f $li.sid,$lc,$li.release)
        Write-Host ("IDENT: side=R sid={0} client={1} release={2}" -f $ri.sid,$rc,$ri.release)
        if ($li.sid -and $li.sid -eq $ri.sid -and $lc -eq $rc) {
            Write-Host "STATUS: CFG_SAME_IDENTITY sid=$($li.sid) client=$lc"; Disconnect-SapRfc; exit 1
        }

        # ---- resolve object on both -----------------------------------------
        $rl = Resolve-Object $left $obj; $rr = Resolve-Object $right $obj
        $missL = (-not $rl -or $rl.kind -eq 'VIEW_UNRESOLVED'); $missR = (-not $rr -or $rr.kind -eq 'VIEW_UNRESOLVED')
        if ($missL -or $missR) {
            $side = if ($missL -and $missR) { 'both' } elseif ($missL) { 'left' } else { 'right' }
            Write-Host "STATUS: CFG_OBJECT_NOT_FOUND object=$obj side=$side"; Disconnect-SapRfc; exit 1
        }
        $readTgt = $rl.read_target
        $scopeNotes = @(); if ($rl.note) { $scopeNotes += $rl.note }
        Write-Host ("OBJECT: kind={0} read_target={1} note=`"{2}`"" -f $rl.kind,$readTgt,(San $rl.note))

        # ---- field metadata both sides --------------------------------------
        $fiL = Get-FieldInfo $left  $readTgt
        $fiR = Get-FieldInfo $right $rr.read_target
        if (-not $fiL.Count -or -not $fiR.Count) { Write-Host "STATUS: RFC_ERROR fieldinfo_empty target=$readTgt"; Disconnect-SapRfc; exit 2 }
        $rmap = @{}; foreach ($f in $fiR) { $rmap[$f.field] = $f }
        $onlyLeft  = @($fiL | Where-Object { -not $rmap.ContainsKey($_.field) } | ForEach-Object { $_.field })
        $onlyRight = @($fiR | Where-Object { $fiL.field -notcontains $_.field } | ForEach-Object { $_.field })

        # keys / compared field sets. The technical MANDT/CLNT leading key is dropped
        # ONLY for client-DEPENDENT tables (DD02L CLIDEP='X'): there RFC_READ_TABLE auto-
        # filters to the logon client, so MANDT is constant (100 vs 800) and useless as a
        # join key -- we join on the remaining keys. For a client-INDEPENDENT table (e.g.
        # T000, the client table itself) MANDT IS the real key and is kept.
        $common = @($fiL | Where-Object { $rmap.ContainsKey($_.field) })
        $clidep = ''
        try { $cd = Read-One $left 'DD02L' "TABNAME = '$readTgt'" @('CLIDEP'); if ($cd) { $clidep = $cd['CLIDEP'] } } catch { }
        $dropClnt = ($clidep -eq 'X')
        $allKeys = @($common | Where-Object { $_.key } | Sort-Object position)
        $nonClntKeys = @($allKeys | Where-Object { $_.datatype -ne 'CLNT' })
        if ($dropClnt) {
            if ($nonClntKeys.Count -ge 1) { $keyFlds = $nonClntKeys }
            else { Write-Host "STATUS: CFG_NO_COMMON_KEY object=$obj reason=single_client_key_table"; Disconnect-SapRfc; exit 1 }
        } else {
            $keyFlds = $allKeys
        }
        if ($keyFlds.Count -eq 0) { Write-Host "STATUS: CFG_NO_COMMON_KEY object=$obj"; Disconnect-SapRfc; exit 1 }
        $keyW = ($keyFlds | Measure-Object outlen -Sum).Sum
        $restrict = @(); if ($Fields) { $restrict = @($Fields.ToUpper() -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        $excluded = @()
        $valFlds = @()
        foreach ($f in ($common | Where-Object { -not $_.key } | Sort-Object position)) {
            if ($f.datatype -eq 'CLNT' -and $dropClnt) { continue }
            if ($restrict.Count -and ($restrict -notcontains $f.field)) { continue }
            if ($f.datatype -in @('STRG','RSTR','LRAW','RAWSTRING')) { $excluded += ,([pscustomobject]@{ name=$f.field; reason="datatype_$($f.datatype)_not_readable" }); continue }
            if (([int]$f.outlen + [int]$keyW) -gt 512) { $excluded += ,([pscustomobject]@{ name=$f.field; reason="too_wide_outlen_$($f.outlen)" }); continue }
            $valFlds += ,$f
        }
        if ($KeysOnly) { $valFlds = @() }
        Write-Host ("FIELDS: keys={0} compared={1} excluded={2} only_left={3} only_right={4}" -f $keyFlds.Count,$valFlds.Count,$excluded.Count,$onlyLeft.Count,$onlyRight.Count)

        # ---- WHERE + unbounded guard ----------------------------------------
        $whereStr = Build-Where $Where $Options
        if (-not $whereStr) {
            # keys-only probe ROWCOUNT=effMax+1 each side
            function Probe-Count { param($d) $fn=New-RfcReadTable -Destination $d -Table $readTgt -Delimiter ''; [void]$fn.SetValue('ROWCOUNT',$effMax+1); Add-RfcField $fn $keyFlds[0].field; if (-not (Invoke-Rfc $fn $d)) { return 0 }; return [int]$fn.GetTable('DATA').RowCount }
            $cntL = Probe-Count $left; $cntR = Probe-Count $right
            if ($cntL -gt $effMax -or $cntR -gt $effMax) {
                $sug = $keyFlds[0].field
                Write-Host ("STATUS: CFG_UNBOUNDED_READ object=$obj left=$cntL right=$cntR max=$effMax suggest_filter=$sug"); Disconnect-SapRfc; exit 1
            }
        }

        # ---- chunked read both sides ----------------------------------------
        $colOrder = @($keyFlds | ForEach-Object { $_.field }) + @($valFlds | ForEach-Object { $_.field })
        $header = ($colOrder -join "`t")
        foreach ($sidePair in @(@('L',$left,$readTgt),@('R',$right,$rr.read_target))) {
            $sd=$sidePair[0]; $dd=$sidePair[1]; $tt=$sidePair[2]
            $res = Read-Chunked $dd $tt $whereStr $keyFlds $valFlds $effMax
            $lines = @()
            foreach ($k in $res.order) { $rec=$res.rows[$k]; $lines += (($colOrder | ForEach-Object { San $rec[$_] }) -join "`t") }
            $fname = if ($sd -eq 'L') { 'left.tsv' } else { 'right.tsv' }
            Write-Tsv (Join-Path $OutDir $fname) $header $lines
            Write-Host ("READ: side={0} rows={1} capped={2} groups={3}" -f $sd,$res.order.Count,$(if($res.capped){'Y'}else{'N'}),$res.groups)
            if ($sd -eq 'L') { $script:lcap=$res.capped; $script:lrows=$res.order.Count } else { $script:rcap=$res.capped; $script:rrows=$res.order.Count }
        }

        # ---- texts.tsv: DD02T table text + DD04T per compared ROLLNAME -------
        $txtLines = @()
        try { $tt2 = Read-One $left 'DD02T' "TABNAME = '$readTgt' AND DDLANGUAGE = 'E'" @('TABNAME','DDTEXT'); if ($tt2 -and $tt2['DDTEXT']) { $txtLines += ("table`t{0}`t{1}" -f $readTgt,(San $tt2['DDTEXT'])) } } catch { }
        $rolls = @($valFlds + $keyFlds | ForEach-Object { $_.rollname } | Where-Object { $_ } | Sort-Object -Unique)
        foreach ($rn in $rolls) { try { $dtt = Read-One $left 'DD04T' "ROLLNAME = '$rn' AND DDLANGUAGE = 'E'" @('ROLLNAME','DDTEXT'); if ($dtt -and $dtt['DDTEXT']) { $txtLines += ("field`t{0}`t{1}" -f $rn,(San $dtt['DDTEXT'])) } } catch { } }
        Write-Tsv (Join-Path $OutDir 'texts.tsv') "kind`tname`ttext" $txtLines

        # ---- meta.json ------------------------------------------------------
        $exJson = ($excluded | ForEach-Object { "{`"name`":`"$(JEsc $_.name)`",`"reason`":`"$(JEsc $_.reason)`"}" }) -join ','
        $scopeJson = ($scopeNotes | ForEach-Object { "`"$(JEsc $_)`"" }) -join ','
        $keyJson = ($keyFlds | ForEach-Object { "`"$($_.field)`"" }) -join ','
        $cmpJson = ($valFlds | ForEach-Object { "`"$($_.field)`"" }) -join ','
        $olJson = ($onlyLeft | ForEach-Object { "`"$_`"" }) -join ','
        $orJson = ($onlyRight | ForEach-Object { "`"$_`"" }) -join ','
        $capd = ($script:lcap -or $script:rcap)
        $meta = @"
{
  "schema": "sapdev.configcompare.meta/1",
  "object": "$(JEsc $obj)",
  "kind": "$(JEsc $rl.kind)",
  "read_target": "$(JEsc $readTgt)",
  "left":  { "sid": "$(JEsc $li.sid)", "client": "$(JEsc $lc)", "release": "$(JEsc $li.release)", "rows": $($script:lrows + 0) },
  "right": { "sid": "$(JEsc $ri.sid)", "client": "$(JEsc $rc)", "release": "$(JEsc $ri.release)", "rows": $($script:rrows + 0) },
  "key_columns": [$keyJson],
  "compared_columns": [$cmpJson],
  "excluded_columns": [$exJson],
  "only_left_columns": [$olJson],
  "only_right_columns": [$orJson],
  "scope_notes": [$scopeJson],
  "keys_only": $(if($KeysOnly){'true'}else{'false'}),
  "capped": $(if($capd){'true'}else{'false'}),
  "filter": "$(JEsc $whereStr)",
  "max_rows": $effMax
}
"@
        [System.IO.File]::WriteAllText((Join-Path $OutDir 'meta.json'), $meta, (New-Object System.Text.UTF8Encoding($false)))

        Write-Host "STATUS: OK"
        Disconnect-SapRfc; exit 0
    } catch {
        Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host "STATUS: RFC_ERROR"; try { Disconnect-SapRfc } catch { }; exit 2
    }
}
