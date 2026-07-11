# =============================================================================
# sap_seq_read.ps1  -  transport-set reader for /sap-transport-sequencer (RFC, read-only)
#
# Reads a set of transport requests from the SOURCE system over pure RFC and writes
# the raw material the offline graph engine orders:
#   headers.tsv  - E070 header per TR (+ E07T text, computed release_ts)
#   objects.tsv  - E071 objects, NORMALIZED (LIMU folded into its R3TR parent) so two
#                  TRs touching different pieces of the same class/program count as one
#                  overlap; FUNC->FUGR via a batched ENLFDIR read
#   overlaps.tsv - reverse scan: OTHER TRs (not in the input set) touching a listed
#                  normalized object -> predecessor candidates / overtaker risk
#   tasks.tsv    - unreleased tasks under a listed (released) header (E070 STRKORR IN set)
#
# READ-ONLY. RFC_READ_TABLE only (E070/E07T/E071/ENLFDIR all FMODE=R, TRANSP, probed
# identical S4D + EC2 2026-07-11). Never imports, never releases.
#
#   -Trs "TR1,TR2,..." [-MaxTrs 200] -OutDir <dir>
#
# stdout (parseable by SKILL.md):
#   TR: trkorr=<..> status=<R|D|L|..> released=<Y|N> objects=<n> text="<..>"
#   MISSING: trkorr=<..>                       (a requested TR not found in E070)
#   OVERLAP_EXT: object=<..> tr=<..> status=<..>  (reverse-scan hit outside the set)
#   STATUS: OK | SEQ_TR_NOT_FOUND | RFC_ERROR  found=<n> missing=<n>
# Exit: 0 OK | 1 some TR not found (unless -SkipMissing) | 2 connect/RFC failure.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Trs        = '',
    [int]    $MaxTrs     = 200,
    [switch] $SkipMissing,
    [string] $OutDir     = '',
    [string] $SharedDir  = '',
    [string] $RunId      = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
foreach ($lib in 'sap_connection_lib.ps1','sap_rfc_lib.ps1','sap_object_resolver.ps1') { $pp = Join-Path $scripts $lib; if (Test-Path $pp) { . $pp } }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Write-Tsv { param([string]$Path,[string]$Header,[object[]]$Lines)
    $sb = New-Object System.Text.StringBuilder; [void]$sb.AppendLine($Header)
    foreach ($l in $Lines) { [void]$sb.AppendLine($l) }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}

# ---- LIMU -> R3TR parent normalization ---------------------------------------
# Fold a transport object to the repository object whose overlap actually matters, so
# two TRs editing different pieces of ZCL_X both resolve to CLAS:ZCL_X.
$script:_enlf = @{}
function Normalize-Obj { param($d,[string]$pgmid,[string]$object,[string]$name)
    $o = $object.ToUpper(); $n = $name.Trim()
    switch -Regex ($o) {
        '^(REPS|REPT|REPO|DYNP|CUAD|PROG)$' { return @{ object='PROG'; name=($n -split '\s+')[0] } }
        '^(CLSD|CPUB|CPRI|CPRO|CINC|CDEF|CDOC|METH|CLAS)$' { return @{ object='CLAS'; name=(($n.Substring(0,[Math]::Min(30,$n.Length))).Trim()) } }
        '^(FUNC)$' {
            $fg = $script:_enlf[$n]
            if (-not $fg) {
                try { $r = Read-SapTableRows -Destination $d -Table 'ENLFDIR' -Where "FUNCNAME = '$($n -replace "'","''")'" -Fields @('AREA') -RowCount 1; if (@($r).Count) { $fg = (San $r[0].AREA) } } catch { }
                if (-not $fg) { $fg = $n }; $script:_enlf[$n] = $fg
            }
            return @{ object='FUGR'; name=$fg }
        }
        '^(FUGR|FUGT)$' { return @{ object='FUGR'; name=$n } }
        '^(TABD|TABT|INDX)$' { return @{ object='TABL'; name=$n } }
        default { return @{ object=$o; name=$n } }
    }
}

# RFC_READ_TABLE raises TABLE_WITHOUT_DATA (exception) for an empty selection on some
# kernels. Treat as 0 rows, not an error.
function Invoke-Rfc { param($fn,$d) try { $fn.Invoke($d); return $true } catch { if ("$($_.Exception.Message)" -match 'TABLE_WITHOUT_DATA') { return $false } else { throw } } }

# Batched read for a set of key values. RFC_READ_TABLE has NO SQL `IN` operator, so we
# build OR'd equalities packed into <=72-char OPTIONS rows (continuation rows start with
# 'OR'), and parse the fixed-width DATA by the FIELDS OFFSET/LENGTH (delimiter-proof).
function Read-InSet { param($d,[string]$table,[string]$keyField,[string[]]$keys,[string[]]$fields)
    $out = @()
    for ($i=0; $i -lt $keys.Count; $i += 30) {
        $chunk = $keys[$i..([Math]::Min($i+29,$keys.Count-1))]
        $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''
        [void]$fn.SetValue('ROWCOUNT',20000)
        $line = ''
        for ($k=0; $k -lt $chunk.Count; $k++) {
            $pred = "$keyField = '" + ($chunk[$k] -replace "'","''") + "'"
            $piece = if ($k -eq 0) { $pred } else { "OR $pred" }
            if ($line -eq '') { $line = $piece }
            elseif (($line.Length + 1 + $piece.Length) -le 72) { $line = "$line $piece" }
            else { Add-RfcOption $fn $line; $line = $piece }
        }
        if ($line) { Add-RfcOption $fn $line }
        foreach ($f in $fields) { Add-RfcField $fn $f }
        if (-not (Invoke-Rfc $fn $d)) { continue }
        $fm = $fn.GetTable('FIELDS'); $off=@{}; $len=@{}
        for ($x=0;$x -lt $fm.RowCount;$x++){$fm.CurrentIndex=$x;$nm=("$($fm.GetString('FIELDNAME'))").Trim();$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
        $dt = $fn.GetTable('DATA')
        for ($x=0;$x -lt $dt.RowCount;$x++){$dt.CurrentIndex=$x;$wa="$($dt.GetString('WA'))";$rec=[ordered]@{};foreach($f in $fields){$o=$off[$f];$l=$len[$f];$rec[$f]=if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).TrimEnd()}else{''}};$out+=,([pscustomobject]$rec)}
    }
    return $out
}

if ($MyInvocation.InvocationName -eq '.') { return }

if (-not $Trs)    { Write-Host 'STATUS: RFC_ERROR no_trs'; exit 2 }
if (-not $OutDir) { Write-Host 'STATUS: RFC_ERROR no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$trList = @($Trs.ToUpper() -split '[,\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($trList.Count -eq 0) { Write-Host 'STATUS: RFC_ERROR empty_trs'; exit 2 }
if ($trList.Count -gt $MaxTrs) { Write-Host "STATUS: SEQ_INPUT_INVALID count=$($trList.Count) max=$MaxTrs"; exit 2 }

$dest = $null; try { $dest = Connect-SapRfc -DestName 'SEQ_SRC' } catch { }
if (-not $dest) { Write-Host 'STATUS: RFC_LOGON_FAILED'; exit 2 }

try {
    # ---- headers -------------------------------------------------------------
    $hdrRows = Read-InSet $dest 'E070' 'TRKORR' $trList @('TRKORR','TRFUNCTION','TRSTATUS','AS4USER','AS4DATE','AS4TIME','STRKORR')
    $hmap = @{}; foreach ($h in @($hdrRows)) { $hmap[(San $h.TRKORR)] = $h }
    $found = @(); $missing = @()
    foreach ($tr in $trList) { if ($hmap.ContainsKey($tr)) { $found += $tr } else { $missing += $tr; Write-Host "MISSING: $tr" } }
    if ($missing.Count -and -not $SkipMissing) { Write-Host "STATUS: SEQ_TR_NOT_FOUND found=$($found.Count) missing=$($missing.Count)"; Disconnect-SapRfc; exit 1 }

    # texts
    $txtRows = Read-InSet $dest 'E07T' 'TRKORR' $found @('TRKORR','LANGU','AS4TEXT')
    $txt = @{}; foreach ($x in @($txtRows)) { $k=(San $x.TRKORR); $lg=(San $x.LANGU); if ($k -and (-not $txt.ContainsKey($k) -or $lg -eq 'E')) { $txt[$k] = San $x.AS4TEXT } }

    $hdrLines = @()
    foreach ($tr in $found) {
        $h = $hmap[$tr]; $st=(San $h.TRSTATUS); $rel = ($st -eq 'R' -or $st -eq 'O')
        $ts = (San $h.AS4DATE) + (San $h.AS4TIME)
        $hdrLines += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}" -f $tr,(San $h.TRFUNCTION),$st,$(if($rel){'Y'}else{'N'}),(San $h.AS4USER),(San $h.AS4DATE),(San $h.AS4TIME),$ts,($txt[$tr] -replace "`t",' '))
        Write-Host ("TR: trkorr={0} status={1} released={2} objects=? text=`"{3}`"" -f $tr,$st,$(if($rel){'Y'}else{'N'}),(($txt[$tr]) -replace '"',"'"))
    }
    Write-Tsv (Join-Path $OutDir 'headers.tsv') "trkorr`ttrfunction`ttrstatus`treleased`tas4user`tas4date`tas4time`trelease_ts`ttext" $hdrLines

    # ---- objects (normalized) -----------------------------------------------
    $objRows = Read-InSet $dest 'E071' 'TRKORR' $found @('TRKORR','PGMID','OBJECT','OBJ_NAME','LOCKFLAG')
    $objLines = @(); $normSet = @{}   # normKey -> @(trs)
    foreach ($o in @($objRows)) {
        $pg=(San $o.PGMID); if ($pg -notin @('R3TR','LIMU')) { continue }
        $norm = Normalize-Obj $dest $pg (San $o.OBJECT) (San $o.OBJ_NAME)
        $nk = $norm.object + ':' + $norm.name
        $tr = San $o.TRKORR
        $objLines += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $tr,$norm.object,$norm.name,$pg,(San $o.OBJECT),(San $o.OBJ_NAME),(San $o.LOCKFLAG))
        if (-not $normSet.ContainsKey($nk)) { $normSet[$nk] = New-Object System.Collections.ArrayList }
        [void]$normSet[$nk].Add($tr)
    }
    Write-Tsv (Join-Path $OutDir 'objects.tsv') "trkorr`tnorm_object`tnorm_name`torig_pgmid`torig_object`torig_name`tlockflag" $objLines
    # object count per TR back-fill for stdout was '?'; recompute quickly
    $cntByTr = @{}; foreach ($l in $objLines) { $t=($l -split "`t")[0]; if (-not $cntByTr.ContainsKey($t)) { $cntByTr[$t]=0 }; $cntByTr[$t]++ }

    # ---- reverse-overlap scan (other TRs touching a listed normalized object) --
    # Query E071 by the ORIGINAL object/name is expensive; instead scan by normalized
    # R3TR name for the distinct set, capped. We look up other TRs via OBJ_NAME match.
    # scan E071 by normalized R3TR name for OTHER TRs touching a listed object, then
    # AGGREGATE PER EXTERNAL TR (one row each, not one per object) so a shared dev's long
    # history collapses to a handful of actionable rows: still-modifiable overtakers and
    # the immediate released predecessor. The graph decides the category.
    $distinct = @($normSet.Keys)
    $scanNames = @($distinct | ForEach-Object { ($_ -split ':',2)[1] } | Where-Object { $_ } | Sort-Object -Unique)
    $ext = @(Read-InSet $dest 'E071' 'OBJ_NAME' $scanNames @('TRKORR','PGMID','OBJECT','OBJ_NAME'))
    $extTrs = @($ext | ForEach-Object { San $_.TRKORR } | Where-Object { $_ -and ($found -notcontains $_) } | Sort-Object -Unique)
    $extHdr = @{}; if ($extTrs.Count) { $eh = Read-InSet $dest 'E070' 'TRKORR' $extTrs @('TRKORR','TRSTATUS','AS4USER','AS4DATE','AS4TIME'); foreach ($e in @($eh)) { $extHdr[(San $e.TRKORR)] = $e } }
    $extAgg = @{}   # etr -> @{ est; ets; user; objs=HashSet; minListedTs }
    foreach ($e in @($ext)) {
        $etr = San $e.TRKORR; if (-not $etr -or ($found -contains $etr)) { continue }
        $norm = Normalize-Obj $dest (San $e.PGMID) (San $e.OBJECT) (San $e.OBJ_NAME); $nk = $norm.object+':'+$norm.name
        if (-not $normSet.ContainsKey($nk)) { continue }
        if (-not $extAgg.ContainsKey($etr)) {
            $eh2 = $extHdr[$etr]
            $extAgg[$etr] = @{ est=$(if($eh2){San $eh2.TRSTATUS}else{''}); ets=$(if($eh2){(San $eh2.AS4DATE)+(San $eh2.AS4TIME)}else{''}); user=$(if($eh2){San $eh2.AS4USER}else{''}); objs=(New-Object System.Collections.Generic.HashSet[string]) }
        }
        [void]$extAgg[$etr].objs.Add($nk)
    }
    # min listed ts per external TR (over its shared objects' listed TRs)
    $ovLines = @()
    foreach ($etr in $extAgg.Keys) {
        $a = $extAgg[$etr]; $shared = @($a.objs)
        $minListed = ($shared | ForEach-Object { $normSet[$_] } | ForEach-Object { $_ } | Where-Object { $hmap.ContainsKey($_) } | ForEach-Object { (San $hmap[$_].AS4DATE)+(San $hmap[$_].AS4TIME) } | Where-Object { $_ } | Sort-Object | Select-Object -First 1)
        $ovLines += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f $etr,$a.est,$a.ets,$a.user,($shared -join '|'),$minListed)
    }
    # bound: keep modifiable (overtakers) always; keep released only if immediate predecessor
    Write-Tsv (Join-Path $OutDir 'overlaps.tsv') "ext_trkorr`text_status`text_ts`text_user`tshared_objs`tmin_listed_ts" $ovLines
    Write-Host ("OVERLAP_SCAN: external_trs=$($extAgg.Count) scanned_objects=$($scanNames.Count)")

    # ---- task sweep: unreleased tasks under a listed released header ---------
    $taskRows = Read-InSet $dest 'E070' 'STRKORR' $found @('TRKORR','TRSTATUS','STRKORR','AS4USER')
    $taskLines = @()
    foreach ($t in @($taskRows)) { $ts=(San $t.TRSTATUS); if ($ts -ne 'R' -and $ts -ne 'O') { $taskLines += ("{0}`t{1}`t{2}`t{3}" -f (San $t.STRKORR),(San $t.TRKORR),$ts,(San $t.AS4USER)) } }
    Write-Tsv (Join-Path $OutDir 'tasks.tsv') "parent_trkorr`ttask`ttask_status`tuser" $taskLines

    Write-Host ("STATUS: OK found=$($found.Count) missing=$($missing.Count)")
    Disconnect-SapRfc; exit $(if ($missing.Count) { 1 } else { 0 })
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
