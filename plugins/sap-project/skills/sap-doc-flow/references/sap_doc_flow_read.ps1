# =============================================================================
# sap_doc_flow_read.ps1  -  O2C document-flow walker for /sap-doc-flow (RFC, read-only)
#
# Walks VBFA in BOTH directions from a business document (order/delivery/invoice),
# decodes every node's status RELEASE-AWARE (S/4 in-table VBAK/LIKP/VBRK vs ECC VBUK),
# follows the invoice into FI via BKPF/AWKEY, and writes a node/edge map + optional
# /sap-diagnose evidence file. Pure RFC (RFC_READ_TABLE, FMODE=R). Never writes.
#
# Release detection: DD03L probe VBAK-GBSTK -> present = S/4 schema, absent = ECC schema
# (authoritative; VBUK EXISTS on S/4 1909 too, so it can't be the discriminator).
#
#   -Category auto|order|delivery|invoice -DocNo <n> [-MaxNodes 200] [-NoNarrative]
#   -OutDir <dir> [-EvidenceDir <run_dir>]
#
# stdout (parseable by SKILL.md):
#   SCHEMA: <S4|ECC>
#   NODE: cat=<order|delivery|invoice|accounting|other> key=<..> status=<code> health=<OK|OPEN|IN_PROCESS|BLOCKED|CANCELLED|NOT_POSTED|COULD_NOT_CHECK> date=<..> detail="<..>"
#   EDGE: from=<key> to=<key> vbtyp=<v>-><n>
#   STALL: node=<key> reason="<..>"
#   STATUS: OK|DOCFLOW_NOT_FOUND|DOCFLOW_AMBIGUOUS_KEY|RFC_ERROR nodes=<n> truncated=<bool> schema=<S4|ECC>
# Exit: 0 OK | 1 not-found/ambiguous | 2 connect/RFC failure.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Category    = 'auto',
    [string] $DocNo       = '',
    [int]    $MaxNodes    = 200,
    [switch] $NoNarrative,
    [string] $OutDir      = '',
    [string] $EvidenceDir = '',
    [string] $SharedDir   = '',
    [string] $RunId       = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
foreach ($lib in 'sap_connection_lib.ps1','sap_rfc_lib.ps1') { $pp = Join-Path $scripts $lib; if (Test-Path $pp) { . $pp } }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Invoke-Rfc { param($fn,$d) try { $fn.Invoke($d); return $true } catch { $m="$($_.Exception.Message)"; if ($m -match 'TABLE_WITHOUT_DATA' -or $m -match 'FIELD_NOT_VALID') { return $false } else { throw } } }
# offset reader; returns @() on empty/field-invalid (never throws for those)
function Read-Rows { param($d,[string]$table,[string]$where,[string[]]$fields,[int]$max)
    $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''; if ($max -gt 0) { [void]$fn.SetValue('ROWCOUNT',$max) }
    if ($where) { $line=''; foreach ($cl in ($where -split '\s+AND\s+')) { $piece = if ($line -eq '') { $cl } else { "AND $cl" }; if ($line -eq '') { $line=$piece } elseif (($line.Length+1+$piece.Length) -le 72) { $line="$line $piece" } else { Add-RfcOption $fn $line; $line=$piece } }; if ($line) { Add-RfcOption $fn $line } }
    foreach ($f in $fields) { Add-RfcField $fn $f }
    if (-not (Invoke-Rfc $fn $d)) { return @() }
    $fm=$fn.GetTable('FIELDS');$off=@{};$len=@{};for($x=0;$x -lt $fm.RowCount;$x++){$fm.CurrentIndex=$x;$nm=("$($fm.GetString('FIELDNAME'))").Trim();$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
    $dt=$fn.GetTable('DATA');$out=@();for($x=0;$x -lt $dt.RowCount;$x++){$dt.CurrentIndex=$x;$wa="$($dt.GetString('WA'))";$rec=[ordered]@{};foreach($f in $fields){$o=$off[$f];$l=$len[$f];$rec[$f]=if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).Trim()}else{''}};$out+=,([pscustomobject]$rec)}
    return $out
}
function Pad10 { param([string]$k) $k=($k -replace '\s','').TrimStart('0'); if (-not $k) { return '' }; if ($k -match '^\d+$') { return $k.PadLeft(10,'0') }; return $k }

# VBTYP -> node category
function VbtypCat { param([string]$v) switch ($v) { 'C' {'order'} 'J' {'delivery'} 'T' {'delivery'} 'M' {'invoice'} 'O' {'invoice'} 'P' {'invoice'} 'N' {'invoice'} 'H' {'return'} 'R' {'goods_movement'} default {'other'} } }

# health from a status code, per field family
function StatusHealth { param([string]$field,[string]$val)
    $v = $val.Trim()
    switch ($field) {
        'GBSTK' { if ($v -eq 'C') {'OK'} elseif ($v -eq 'B') {'IN_PROCESS'} elseif ($v -eq 'A' -or $v -eq '') {'OPEN'} else {'OPEN'} }
        'WBSTK' { if ($v -eq 'C') {'OK'} elseif ($v -eq 'B') {'IN_PROCESS'} else {'OPEN'} }
        'FKSTK' { if ($v -eq 'C') {'OK'} elseif ($v -eq 'B') {'IN_PROCESS'} else {'OPEN'} }
        'ABSTK' { if ($v -eq 'C') {'CANCELLED'} elseif ($v -eq 'B') {'BLOCKED'} else {'OK'} }
        'RFBSK' { if ($v -eq 'C') {'OK'} elseif ($v -eq '' -or $v -eq 'A') {'NOT_POSTED'} else {'IN_PROCESS'} }
        default { 'COULD_NOT_CHECK' }
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $DocNo)  { Write-Host 'STATUS: RFC_ERROR no_docno'; exit 2 }
if (-not $OutDir) { Write-Host 'STATUS: RFC_ERROR no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$key = Pad10 $DocNo
if (-not $key) { Write-Host 'STATUS: DOCFLOW_NOT_FOUND bad_key'; exit 1 }

$dest = $null; try { $dest = Connect-SapRfc -DestName 'DOCFLOW' } catch { }
if (-not $dest) { Write-Host 'STATUS: RFC_LOGON_FAILED'; exit 2 }

try {
    # ---- release schema ------------------------------------------------------
    $probe = @(Read-Rows $dest 'DD03L' "TABNAME = 'VBAK' AND FIELDNAME = 'GBSTK'" @('FIELDNAME') 1)
    $schema = if (@($probe).Count) { 'S4' } else { 'ECC' }
    Write-Host "SCHEMA: $schema"

    # ---- category auto-detect ------------------------------------------------
    function Exists { param($tab) return (@(Read-Rows $dest $tab "VBELN = '$key'" @('VBELN') 1).Count -gt 0) }
    $cat = $Category
    if ($cat -eq 'auto') {
        $hits = @()
        if (Exists 'VBAK') { $hits += 'order' }
        if (Exists 'LIKP') { $hits += 'delivery' }
        if (Exists 'VBRK') { $hits += 'invoice' }
        if ($hits.Count -eq 0) { Write-Host "STATUS: DOCFLOW_NOT_FOUND key=$key schema=$schema"; Disconnect-SapRfc; exit 1 }
        if ($hits.Count -gt 1) {
            if ($EvidenceDir) { Write-Host "STATUS: DOCFLOW_AMBIGUOUS_KEY key=$key cats=$($hits -join ',') schema=$schema"; Disconnect-SapRfc; exit 1 }
            # interactive: pick the earliest in the O2C order deterministically for the reader
            $cat = $hits[0]
        } else { $cat = $hits[0] }
    }

    # ---- VBFA BFS both directions -------------------------------------------
    $nodes = [ordered]@{}   # key -> @{cat; vbtyp}
    $edges = @()
    $visited = New-Object System.Collections.Generic.HashSet[string]
    $queue = New-Object System.Collections.Generic.Queue[object]
    $nodes[$key] = @{ cat=$cat; vbtyp='' }
    $queue.Enqueue(@{ k=$key; depth=0 })
    [void]$visited.Add($key)
    $truncated = $false
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue(); $ck=$cur.k; $depth=$cur.depth
        if ($depth -ge 8) { continue }
        # forward: VBELV = ck -> successors
        $fwd = @(Read-Rows $dest 'VBFA' "VBELV = '$ck'" @('VBELV','VBELN','VBTYP_N','VBTYP_V') 200)
        # backward: VBELN = ck -> predecessors
        $bwd = @(Read-Rows $dest 'VBFA' "VBELN = '$ck'" @('VBELV','VBELN','VBTYP_N','VBTYP_V') 200)
        foreach ($e in $fwd) {
            $nk = San $e.VBELN; if (-not $nk -or $nk -eq $ck) { continue }
            $ec = "$ck->$nk"; if (-not ($edges | Where-Object { $_ -eq $ec })) { $edges += $ec; Write-Host ("EDGE: from=$ck to=$nk vbtyp=$(San $e.VBTYP_V)->$(San $e.VBTYP_N)") }
            if (-not $nodes.Contains($nk)) { $nodes[$nk] = @{ cat=(VbtypCat (San $e.VBTYP_N)); vbtyp=(San $e.VBTYP_N) } }
            if ($nodes.Count -ge $MaxNodes) { $truncated=$true; break }
            if (-not $visited.Contains($nk)) { [void]$visited.Add($nk); $queue.Enqueue(@{ k=$nk; depth=$depth+1 }) }
        }
        if ($truncated) { break }
        foreach ($e in $bwd) {
            $pk = San $e.VBELV; if (-not $pk -or $pk -eq $ck) { continue }
            $ec = "$pk->$ck"; if (-not ($edges | Where-Object { $_ -eq $ec })) { $edges += $ec; Write-Host ("EDGE: from=$pk to=$ck vbtyp=$(San $e.VBTYP_V)->$(San $e.VBTYP_N)") }
            if (-not $nodes.Contains($pk)) { $nodes[$pk] = @{ cat=(VbtypCat (San $e.VBTYP_V)); vbtyp=(San $e.VBTYP_V) } }
            if ($nodes.Count -ge $MaxNodes) { $truncated=$true; break }
            if (-not $visited.Contains($pk)) { [void]$visited.Add($pk); $queue.Enqueue(@{ k=$pk; depth=$depth+1 }) }
        }
        if ($truncated) { break }
    }

    # ---- decode each node ----------------------------------------------------
    $nodeLines = @(); $stalls = @()
    foreach ($nk in $nodes.Keys) {
        $nc = $nodes[$nk].cat; $status=''; $health='COULD_NOT_CHECK'; $date=''; $detail=''
        if ($nc -eq 'invoice') {
            $r = @(Read-Rows $dest 'VBRK' "VBELN = '$nk'" @('VBELN','RFBSK','FKSTO','FKDAT','BUKRS','GJAHR','NETWR','WAERK') 1)
            if (@($r).Count) { $status=San $r[0].RFBSK; $date=San $r[0].FKDAT; if ((San $r[0].FKSTO) -eq 'X') { $health='CANCELLED'; $status='FKSTO' } else { $health=StatusHealth 'RFBSK' $status }; $detail="posting=$status net=$(San $r[0].NETWR)$(San $r[0].WAERK) bukrs=$(San $r[0].BUKRS)"; $nodes[$nk].bukrs=San $r[0].BUKRS; $nodes[$nk].gjahr=San $r[0].GJAHR }
        } elseif ($nc -eq 'order') {
            if ($schema -eq 'S4') { $r = @(Read-Rows $dest 'VBAK' "VBELN = '$nk'" @('VBELN','GBSTK','ABSTK','ERDAT','AUART') 1) }
            else { $r = @(Read-Rows $dest 'VBUK' "VBELN = '$nk'" @('VBELN','GBSTK','ABSTK') 1); $h2=@(Read-Rows $dest 'VBAK' "VBELN = '$nk'" @('ERDAT','AUART') 1) }
            if (@($r).Count) { $gb=San $r[0].GBSTK; $ab=San $r[0].ABSTK; $status=$gb; $health=StatusHealth 'GBSTK' $gb; if ($ab -eq 'C') { $health='CANCELLED' }; $au=if($schema -eq 'S4'){San $r[0].AUART}elseif($h2.Count){San $h2[0].AUART}else{''}; $date=if($schema -eq 'S4'){San $r[0].ERDAT}elseif($h2.Count){San $h2[0].ERDAT}else{''}; $detail="overall=$gb reject=$ab type=$au" }
        } elseif ($nc -eq 'delivery') {
            if ($schema -eq 'S4') { $r = @(Read-Rows $dest 'LIKP' "VBELN = '$nk'" @('VBELN','WBSTK','KOSTK','ERDAT') 1) }
            else { $r = @(Read-Rows $dest 'VBUK' "VBELN = '$nk'" @('VBELN','WBSTK','KOSTK') 1); $h2=@(Read-Rows $dest 'LIKP' "VBELN = '$nk'" @('ERDAT') 1) }
            if (@($r).Count) { $wb=San $r[0].WBSTK; $status=$wb; $health=StatusHealth 'WBSTK' $wb; $date=if($schema -eq 'S4'){San $r[0].ERDAT}elseif($h2.Count){San $h2[0].ERDAT}else{''}; $detail="goods_issue=$wb picking=$(San $r[0].KOSTK)" }
        }
        if ($health -in @('OPEN','IN_PROCESS','BLOCKED','NOT_POSTED')) { $stalls += @{ k=$nk; cat=$nc; reason="$nc status=$status ($health)" }; Write-Host ("STALL: node=$nk reason=`"$nc $health status=$status`"") }
        Write-Host ("NODE: cat=$nc key=$nk status=$status health=$health date=$date detail=`"$detail`"")
        $nodeLines += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f $nk,$nc,$status,$health,$date,($detail -replace "`t",' '))

        # BKPF hop for invoice
        if ($nc -eq 'invoice' -and $nodes[$nk].bukrs) {
            $bk = @(); foreach ($awk in @($nk, ($nk + $nodes[$nk].gjahr))) { $bk = @(Read-Rows $dest 'BKPF' "AWTYP = 'VBRK' AND AWKEY = '$awk' AND BUKRS = '$($nodes[$nk].bukrs)'" @('BELNR','GJAHR','BUKRS','STBLG','BLDAT') 2); if (@($bk).Count) { break } }
            if (@($bk).Count) { $rev=if((San $bk[0].STBLG)){'CANCELLED'}else{'OK'}; Write-Host ("NODE: cat=accounting key=$(San $bk[0].BELNR) status=posted health=$rev date=$(San $bk[0].BLDAT) detail=`"FI doc bukrs=$(San $bk[0].BUKRS) gjahr=$(San $bk[0].GJAHR)`""); $nodeLines += ("$(San $bk[0].BELNR)`taccounting`tposted`t$rev`t$(San $bk[0].BLDAT)`tFI doc for invoice $nk"); $edges += "$nk->$(San $bk[0].BELNR)"; Write-Host ("EDGE: from=$nk to=$(San $bk[0].BELNR) vbtyp=M->FI") }
            else { Write-Host ("NODE: cat=accounting key=- status=NOT_LINKED health=NOT_POSTED date= detail=`"no BKPF row for invoice $nk (AWKEY tried $nk / $nk+GJAHR)`""); $nodeLines += ("-`taccounting`tNOT_LINKED`tNOT_POSTED`t`tno FI document for invoice $nk"); $stalls += @{ k=$nk; cat='accounting'; reason="invoice $nk not posted to FI" } }
        }
    }

    # ---- write outputs -------------------------------------------------------
    $sb = New-Object System.Text.StringBuilder; [void]$sb.AppendLine("key`tcategory`tstatus`thealth`tdate`tdetail")
    foreach ($l in $nodeLines) { [void]$sb.AppendLine($l) }
    [IO.File]::WriteAllText((Join-Path $OutDir 'docflow_nodes.tsv'), $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
    $eb = New-Object System.Text.StringBuilder; [void]$eb.AppendLine("from`tto")
    foreach ($e in $edges) { $p=$e -split '->',2; [void]$eb.AppendLine("$($p[0])`t$($p[1])") }
    [IO.File]::WriteAllText((Join-Path $OutDir 'docflow_edges.tsv'), $eb.ToString(), (New-Object Text.UTF8Encoding($true)))

    if ($EvidenceDir) {
        if (-not (Test-Path $EvidenceDir)) { New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null }
        $keysJson = (@($nodes.Keys) | ForEach-Object { "`"$_`"" }) -join ','
        $ev = "{`n  ""schema_ver"": ""evidence_file/1"",`n  ""source"": ""DOCFLOW"",`n  ""anchor"": ""$key"",`n  ""schema"": ""$schema"",`n  ""object_keys"": [$keysJson],`n  ""explicit_links"": [$keysJson],`n  ""nodes"": $($nodes.Count),`n  ""stalls"": $($stalls.Count),`n  ""truncated"": $(if($truncated){'true'}else{'false'})`n}`n"
        [IO.File]::WriteAllText((Join-Path $EvidenceDir 'evidence_docflow.json'), $ev, (New-Object Text.UTF8Encoding($false)))
    }

    Write-Host ("STATUS: OK nodes=$($nodes.Count) truncated=$(if($truncated){'true'}else{'false'}) schema=$schema stalls=$($stalls.Count)")
    Disconnect-SapRfc; exit 0
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
