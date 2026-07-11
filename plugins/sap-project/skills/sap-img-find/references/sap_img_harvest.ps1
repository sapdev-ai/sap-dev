# =============================================================================
# sap_img_harvest.ps1  -  one-time IMG activity-index harvest for /sap-img-find (read-only)
#
# Dumps the SPRO/IMG index tables over RFC (all TRANSP, RFC_READ_TABLE FMODE=R, probed
# identical S4D + EC2 2026-07-11) into a per-system local cache, reconstructing each IMG
# node's full SPRO path from the TNODEIMG parent chain. Client-independent tables (no MANDT).
# No SAP writes; no wrapper FM (STREE_GET_PATH_TO_NODE FMODE-blank path avoided -- path is
# rebuilt locally, so the skill has zero dev-init dependency).
#
# Index model (node-centric -- the searchable SPRO label is the NODE text, not CUS_IMGACT
# which holds generic "Notes on Implementation" docs):
#   TNODEIMGT  NODE_ID -> TEXT (SPRO label, SPRAS=E)     <- search corpus
#   TNODEIMG   NODE_ID -> PARENT_ID / EXT_KEY            <- path reconstruction
#   TNODEIMGR  NODE_ID -> REF_OBJECT (IMG activity)      <- node -> activity link
#   CUS_IMGACH ACTIVITY -> C_ACTIVITY / TCODE            <- activity -> generated tcode
#   CUS_ACTOBJ ACT_ID -> OBJECTTYPE / OBJECTNAME         <- activity -> maintenance objects
#
# Output: {CacheDir}\img_index.tsv (ext_key, node_text, spro_path, activity, tcode, objects),
#         {CacheDir}\meta.json. Every table paginated (ROWSKIPS/ROWCOUNT).
#
#   -CacheDir <dir> [-Lang E] [-Max 200000] [-Profile <hint>]
# stdout: IMGH: table=<t> rows=<n> lines + IMGH: INDEX activities=<a> nodes=<n> + STATUS: OK|IMG_*
# =============================================================================

[CmdletBinding()]
param(
    [string] $CacheDir  = '',
    [string] $Lang      = 'E',
    [int]    $Max       = 200000,
    [string] $Profile   = '',
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

# paginated offset reader (ROWSKIPS + ROWCOUNT); returns all rows up to $cap
function Read-All { param($d,[string]$table,[string]$where,[string[]]$fields,[int]$cap)
    $page=5000; $skip=0; $out=@()
    while ($out.Count -lt $cap) {
        $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''
        [void]$fn.SetValue('ROWCOUNT',$page); [void]$fn.SetValue('ROWSKIPS',$skip)
        if ($where) { Add-RfcOption $fn $where }
        foreach ($f in $fields) { Add-RfcField $fn $f }
        if (-not (Invoke-Rfc $fn $d)) { break }
        $fm=$fn.GetTable('FIELDS');$off=@{};$len=@{};for($x=0;$x -lt $fm.RowCount;$x++){$fm.CurrentIndex=$x;$nm=(San $fm.GetString('FIELDNAME'));$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
        $dt=$fn.GetTable('DATA'); $n=$dt.RowCount; if ($n -eq 0) { break }
        for($x=0;$x -lt $n;$x++){$dt.CurrentIndex=$x;$wa="$($dt.GetString('WA'))";$rec=[ordered]@{};foreach($f in $fields){$o=$off[$f];$l=$len[$f];$rec[$f]=if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).Trim()}else{''}};$out+=,([pscustomobject]$rec)}
        if ($n -lt $page) { break }
        $skip += $page
    }
    return $out
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $CacheDir) { Write-Host 'STATUS: IMG_HARVEST_INCOMPLETE no_cachedir'; exit 2 }
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null }

$d = $null
if ($Profile) {
    $cands = @(Resolve-SapProfileHint -Hint $Profile)
    if ($cands.Count -ne 1) { Write-Host "STATUS: RFC_LOGON_FAILED profile=$Profile"; exit 2 }
    $c = $cands[0]; $pw = (& (Join-Path $scripts 'sap_dpapi.ps1') -Action unprotect -Value "$($c.password_dpapi)" 2>$null) -as [string]
    try { $d = Connect-SapRfc -Server $c.application_server -Sysnr $c.system_number -MessageServer $c.message_server -LogonGroup $c.logon_group -SystemID $c.system_id -Client $c.client -User $c.user -Password $pw -Language $c.language -DestName ("IMGH_"+$c.system_name) } catch { }
} else { try { $d = Connect-SapRfc -DestName 'IMGH' } catch { } }
if (-not $d) { Write-Host 'STATUS: RFC_LOGON_FAILED'; exit 2 }

try {
    $sid=''; try { $fi=$d.Repository.CreateFunction('RFC_SYSTEM_INFO'); $fi.Invoke($d); $sid=San $fi.GetStructure('RFCSI_EXPORT').GetValue('RFCSYSID') } catch { }
    # --- dump the index tables ---
    $nodeTxt = Read-All $d 'TNODEIMGT' "SPRAS = '$Lang'" @('NODE_ID','EXT_KEY','TEXT') $Max
    Write-Host ("IMGH: table=TNODEIMGT rows=$($nodeTxt.Count)")
    $nodeTree = Read-All $d 'TNODEIMG' '' @('NODE_ID','EXT_KEY','PARENT_ID') $Max
    Write-Host ("IMGH: table=TNODEIMG rows=$($nodeTree.Count)")
    $nodeRef = Read-All $d 'TNODEIMGR' "REF_OBJECT <> ' '" @('NODE_ID','REF_TYPE','REF_OBJECT') $Max
    Write-Host ("IMGH: table=TNODEIMGR rows=$($nodeRef.Count)")
    $act = Read-All $d 'CUS_IMGACH' '' @('ACTIVITY','C_ACTIVITY','TCODE') $Max
    Write-Host ("IMGH: table=CUS_IMGACH rows=$($act.Count)")
    $actObj = Read-All $d 'CUS_ACTOBJ' '' @('ACT_ID','OBJECTTYPE','OBJECTNAME') $Max
    Write-Host ("IMGH: table=CUS_ACTOBJ rows=$($actObj.Count)")

    if ($nodeTxt.Count -eq 0 -or $act.Count -eq 0) { Write-Host 'STATUS: IMG_HARVEST_INCOMPLETE core_table_empty'; Disconnect-SapRfc; exit 1 }

    # --- build lookup maps ---
    $txtById = @{}; foreach ($n in $nodeTxt) { if ($n.NODE_ID) { $txtById[$n.NODE_ID] = San $n.TEXT } }
    $parentById = @{}; foreach ($n in $nodeTree) { if ($n.NODE_ID) { $parentById[$n.NODE_ID] = $n.PARENT_ID } }
    $tcodeByAct = @{}; $cactByAct = @{}; foreach ($a in $act) { $id=San $a.ACTIVITY; if ($id) { $tcodeByAct[$id] = San $a.TCODE; $cactByAct[$id] = San $a.C_ACTIVITY } }
    # objects keyed by C_ACTIVITY (ACT_ID)
    $objByCact = @{}; foreach ($o in $actObj) { $k=San $o.ACT_ID; if ($k) { if (-not $objByCact.ContainsKey($k)) { $objByCact[$k]=@() }; $objByCact[$k] += "$(San $o.OBJECTTYPE):$(San $o.OBJECTNAME)" } }

    # --- path reconstruction (chase PARENT_ID, cap depth 30) ---
    function Get-Path { param([string]$nid)
        $parts=@(); $cur=$nid; $guard=0
        while ($cur -and $guard -lt 30) {
            $t = if ($txtById.ContainsKey($cur)) { $txtById[$cur] } else { '' }
            if ($t) { $parts = ,$t + $parts }
            $p = if ($parentById.ContainsKey($cur)) { $parentById[$cur] } else { '' }
            if (-not $p -or $p -eq $cur) { break }
            $cur = $p; $guard++
        }
        return ($parts -join ' > ')
    }

    # --- denormalized index: one row per node that references an activity ---
    $rows=@(); $seen=@{}
    foreach ($r in $nodeRef) {
        $nid=$r.NODE_ID; $refObj=San $r.REF_OBJECT
        if (-not $refObj) { continue }
        $nodeText = if ($txtById.ContainsKey($nid)) { $txtById[$nid] } else { '' }
        if (-not $nodeText) { continue }   # no searchable label
        # REF_OBJECT is either an IMG activity (-> CUS_IMGACH tcode) or, for a COBJ node, a
        # maintenance view/table directly (-> SM30 target). Resolve both cases.
        $isActivity = $tcodeByAct.ContainsKey($refObj)
        $tcode = if ($isActivity) { $tcodeByAct[$refObj] } else { '' }
        $cact  = if ($cactByAct.ContainsKey($refObj)) { $cactByAct[$refObj] } else { $refObj }
        $objList = if ($objByCact.ContainsKey($cact)) { @($objByCact[$cact]) } else { @() }
        if (-not $isActivity -and $refObj) { $objList = @("$(San $r.REF_TYPE):$refObj") + $objList }   # ref is a direct maintenance object
        $objs = ($objList | Select-Object -Unique -First 6) -join ';'
        $path  = Get-Path $nid
        $key = "$refObj|$nid"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key]=$true
        $rows += (@($refObj,$tcode,$nodeText,$path,$objs) -join "`t")
    }
    $sb=New-Object System.Text.StringBuilder;[void]$sb.AppendLine("activity`ttcode`tnode_text`tspro_path`tobjects")
    foreach ($l in $rows) { [void]$sb.AppendLine($l) }
    [IO.File]::WriteAllText((Join-Path $CacheDir 'img_index.tsv'), $sb.ToString(), (New-Object Text.UTF8Encoding($true)))

    $meta = "{`"schema`":`"sapdev.imgindex/1`",`"sid`":`"$(San $sid)`",`"lang`":`"$Lang`",`"nodes_txt`":$($nodeTxt.Count),`"activities`":$($act.Count),`"index_rows`":$($rows.Count)}"
    [IO.File]::WriteAllText((Join-Path $CacheDir 'meta.json'), $meta, (New-Object Text.UTF8Encoding($false)))
    Write-Host ("IMGH: INDEX activities=$($act.Count) nodes=$($nodeTxt.Count) index_rows=$($rows.Count)")
    Write-Host 'STATUS: OK'
    Disconnect-SapRfc; exit 0
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
