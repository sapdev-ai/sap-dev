# =============================================================================
# sap_note_status_rfc.ps1  -  multi-system SAP Note status matrix for /sap-note-status
#
# Read-only, RFC-only. Fans out over N saved /sap-login profiles and for each
# note x system reports download/implementation status + a mod-collision check.
# Built ONLY on standard remote-enabled reads (RFC_READ_TABLE FMODE=R) so it works
# against PRD/QA with no dev-init artefacts. No GUI, no wrapper FM, no Z object.
#
# Data sources (probed S4D S/4HANA-1909 + EC2 ECC6 2026-07-11):
#   CWBNTHEAD  NUMM/VERSNO -> is the note downloaded? which versions exist
#   CWBNTCUST  NUMM -> NTSTATUS (CWBNTSTAT) + PRSTATUS (CWBPRSTAT) customer status
#   CWBNTFIXED NUMM -> note fixed by an installed delivery event (OBSOLETE_BY_SP hint)
#   CWBNTCI    NUMM -> correction instructions (CIINSTA/CIPAKID/CIALEID/CIVERSNO)
#   CWBCIOBJ   ALEID/... -> touched repository objects (PGMID/OBJECT/OBJ_NAME + TADIR name)
#   SMODILOG   OBJ_NAME -> customer modification/repair log  (=> MOD_COLLISION)
#   TADIR      OBJECT/OBJ_NAME -> object existence + owning package  (=> OBJ_MISSING)
#   CVERS      installed software component levels (skew section)
# NTSTATUS/PRSTATUS have NO DDIC fixed values (application constants); decode comes
# from the shipped, customer-overridable note_status_codes.tsv with a confidence flag;
# the raw code is always carried through.
#
#   -Notes "3123456,2712785" -Systems "S4D,ERP|ALL" [-NoCollisions] [-CodesFile <tsv>]
#   [-MaxObjects 400] -OutDir <dir> [-SharedDir <dir>] [-RunId <id>]
#
# stdout (parsed by SKILL.md):
#   SYSTEM: id=<profile> sid=<SID> client=<C> reachable=YES|NO release=<r> comps="<C:R:SP;..>"
#   NOTE: sid=<SID>/<C> note=<n> downloaded=YES|NO versions=<k> ntstatus=<x> prstatus=<y>
#         verdict=<V> confidence=<D|I|U> objects=<o> mods=<m> missing=<mm> flags=<..> coverage=<..>
#   STATUS: OK|PARTIAL|ERROR systems=<n> reachable=<r> notes=<k>   <detail>
# Writes note_status_rows.tsv + collisions.tsv. Exit 0 OK / 1 partial / 2 fatal.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Notes       = '',
    [string] $Systems     = '',
    [switch] $NoCollisions,
    [string] $CodesFile   = '',
    [int]    $MaxObjects  = 400,
    [string] $OutDir      = '',
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

# RFC_READ_TABLE empty-selection raises TABLE_WITHOUT_DATA on some kernels -> $false.
function Invoke-Rfc { param($fn,$d) try { $fn.Invoke($d); return $true } catch { if ("$($_.Exception.Message)" -match 'TABLE_WITHOUT_DATA') { return $false } else { throw } } }

# WHERE as OPTIONS rows, split at ' AND ' with an AND prefix on continuations, <=72 chars.
function Add-Where { param($fn,[string]$where)
    if (-not $where) { return }
    $line=''
    foreach ($cl in ($where -split '\s+AND\s+')) {
        $piece = if ($line -eq '') { $cl } else { "AND $cl" }
        if ($line -eq '') { $line=$piece } elseif (($line.Length+1+$piece.Length) -le 72) { $line="$line $piece" } else { Add-RfcOption $fn $line; $line=$piece }
    }
    if ($line) { Add-RfcOption $fn $line }
}
# FIELD IN ( 'v1' , 'v2' , ... ) across <=72-char OPTIONS rows (values already fit a field width).
function Add-InList { param($fn,[string]$field,[string[]]$vals)
    Add-RfcOption $fn "$field IN ("
    $line=''
    for ($i=0;$i -lt $vals.Count;$i++) {
        $tok = "'" + (($vals[$i]) -replace "'","''") + "'" + $(if ($i -lt $vals.Count-1) { ' ,' } else { '' })
        if ($line -eq '') { $line=$tok } elseif (($line.Length+1+$tok.Length) -le 72) { $line="$line $tok" } else { Add-RfcOption $fn $line; $line=$tok }
    }
    if ($line) { Add-RfcOption $fn $line }
    Add-RfcOption $fn ")"
}

# Offset-based reader (delimiter '' + FIELDS OFFSET/LENGTH slicing) -- delimiter-proof.
function Read-Rows { param($d,[string]$table,[string]$where,[string[]]$fields,[int]$max,[hashtable]$inList)
    $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''
    if ($max -gt 0) { [void]$fn.SetValue('ROWCOUNT',$max) }
    if ($where)  { Add-Where $fn $where }
    if ($inList) { Add-InList $fn $inList.field $inList.vals }
    foreach ($f in $fields) { Add-RfcField $fn $f }
    if (-not (Invoke-Rfc $fn $d)) { return @() }
    $fm=$fn.GetTable('FIELDS');$off=@{};$len=@{};for($x=0;$x -lt $fm.RowCount;$x++){$fm.CurrentIndex=$x;$nm=(San $fm.GetString('FIELDNAME'));$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
    $dt=$fn.GetTable('DATA');$out=@();for($x=0;$x -lt $dt.RowCount;$x++){$dt.CurrentIndex=$x;$wa="$($dt.GetString('WA'))";$rec=[ordered]@{};foreach($f in $fields){$o=$off[$f];$l=$len[$f];$rec[$f]=if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).Trim()}else{''}};$out+=,([pscustomobject]$rec)}
    return $out   # NOT ',$out' -- caller uses @() on the materialized var only
}

function Norm-Note { param([string]$n)
    $digits = (("$n") -replace '[^0-9]','')
    if (-not $digits -or $digits.Length -gt 10) { return '' }
    return $digits.PadLeft(10,'0')
}

# ---- codes map ---------------------------------------------------------------
if (-not $CodesFile) { $CodesFile = Join-Path $PSScriptRoot 'note_status_codes.tsv' }
$codeMap = @{}   # "FIELD:CODE" -> @{label;verdict;conf}
if (Test-Path $CodesFile) {
    foreach ($ln in ([IO.File]::ReadAllText($CodesFile,[Text.Encoding]::UTF8).TrimStart([char]0xFEFF) -split "`r`n|`n")) {
        if (-not $ln -or $ln.StartsWith('#') -or $ln.StartsWith('field')) { continue }
        $c = $ln -split "`t"; if ($c.Count -lt 5) { continue }
        $codeMap["$($c[0].Trim().ToUpper()):$($c[1].Trim())"] = @{ label=$c[2].Trim(); verdict=$c[3].Trim(); conf=$c[4].Trim() }
    }
}
function Decode { param([string]$field,[string]$code)
    $k = "$($field.ToUpper()):$code"
    if ($codeMap.ContainsKey($k)) { return $codeMap[$k] }
    return @{ label="status code '$code' (see SNOTE)"; verdict='UNKNOWN_STATUS'; conf='UNKNOWN' }
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $OutDir) { Write-Host 'STATUS: ERROR no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

# ---- notes -------------------------------------------------------------------
$noteList = @()
foreach ($n in ($Notes -split ',')) { $t = $n.Trim(); if (-not $t) { continue }; $nn = Norm-Note $t; if (-not $nn) { Write-Host "STATUS: ERROR note_invalid=$t"; exit 2 }; if ($noteList -notcontains $nn) { $noteList += $nn } }
if ($noteList.Count -eq 0) { Write-Host 'STATUS: ERROR no_notes'; exit 2 }

# ---- systems -----------------------------------------------------------------
$store = Read-SapConnectionStore
if (-not $store -or -not $store.connections) { Write-Host 'STATUS: ERROR no_profiles'; exit 2 }
$targets = @()
if (-not $Systems -or $Systems.Trim().ToUpper() -eq 'ALL') {
    $targets = @($store.connections)
} else {
    $seen = @{}
    foreach ($h in ($Systems -split ',')) { $hh=$h.Trim(); if (-not $hh) { continue }
        $m = @(Resolve-SapProfileHint -Hint $hh)
        if ($m.Count -eq 0) { Write-Host "STATUS: ERROR systems_hint_unresolved=$hh"; exit 2 }
        foreach ($p in $m) { if (-not $seen.ContainsKey("$($p.id)")) { $seen["$($p.id)"]=$true; $targets += $p } }
    }
}
$rfcCapable = @($targets | Where-Object { "$($_.password_dpapi)" })
$noPw       = @($targets | Where-Object { -not "$($_.password_dpapi)" })
if ($rfcCapable.Count -eq 0) { Write-Host 'STATUS: ERROR no_rfc_capable_profiles'; exit 2 }

# ---- output accumulators -----------------------------------------------------
$rowLines = @()   # note_status_rows.tsv
$colLines = @()   # collisions.tsv
function JEsc { param([string]$s) return (("$s") -replace "`t",' ' -replace "`r",' ' -replace "`n",' ') }

$reachable = 0
$partial = $false

# no-password systems: one COULD_NOT_CHECK row per note up front
foreach ($p in $noPw) {
    Write-Host ("SYSTEM: id={0} sid={1} client={2} reachable=NO release= comps=`"`" reason=no_rfc_password" -f $p.id,$p.system_name,$p.client)
    $partial = $true
    foreach ($nn in $noteList) {
        Write-Host ("NOTE: sid={0}/{1} note={2} downloaded=NO versions=0 ntstatus= prstatus= verdict=COULD_NOT_CHECK confidence=U objects=0 mods=0 missing=0 flags=NO_RFC_PASSWORD coverage=COULD_NOT_CHECK" -f $p.system_name,$p.client,$nn)
        $rowLines += (@($p.system_name,$p.client,$nn,'NO','0','','','COULD_NOT_CHECK','U','0','0','0','NO_RFC_PASSWORD','COULD_NOT_CHECK','') -join "`t")
    }
}

foreach ($p in $rfcCapable) {
    $pw = (& (Join-Path $scripts 'sap_dpapi.ps1') -Action unprotect -Value "$($p.password_dpapi)" 2>$null) -as [string]
    $d = $null
    try { $d = Connect-SapRfc -Server $p.application_server -Sysnr $p.system_number -MessageServer $p.message_server -LogonGroup $p.logon_group -SystemID $p.system_id -Client $p.client -User $p.user -Password $pw -Language $p.language -DestName ("NS_"+$p.system_name) } catch { }
    if (-not $d) {
        Write-Host ("SYSTEM: id={0} sid={1} client={2} reachable=NO release= comps=`"`" reason=rfc_logon_failed" -f $p.id,$p.system_name,$p.client)
        $partial = $true
        foreach ($nn in $noteList) {
            Write-Host ("NOTE: sid={0}/{1} note={2} downloaded=NO versions=0 ntstatus= prstatus= verdict=COULD_NOT_CHECK confidence=U objects=0 mods=0 missing=0 flags=RFC_LOGON_FAILED coverage=COULD_NOT_CHECK" -f $p.system_name,$p.client,$nn)
            $rowLines += (@($p.system_name,$p.client,$nn,'NO','0','','','COULD_NOT_CHECK','U','0','0','0','RFC_LOGON_FAILED','COULD_NOT_CHECK','') -join "`t")
        }
        continue
    }
    $reachable++
    try {
        # identity
        $sid=''; $rel=''
        try { $fi=$d.Repository.CreateFunction('RFC_SYSTEM_INFO'); $fi.Invoke($d); $si=$fi.GetStructure('RFCSI_EXPORT'); $sid=(San $si.GetValue('RFCSYSID')); $rel=(San $si.GetValue('RFCSAPRL')) } catch { }
        if (-not $sid) { $sid = $p.system_name }
        $cli = ''
        try { $cr = @(Read-Rows $d 'USR02' '' @('MANDT') 1 $null); if ($cr.Count) { $cli = $cr[0].MANDT } } catch { }
        if (-not $cli) { $cli = $p.client }
        # installed components via CVERS
        $comps = @()
        try { $cv = @(Read-Rows $d 'CVERS' '' @('COMPONENT','RELEASE','EXTRELEASE') 300 $null)
              foreach ($r in ($cv | Sort-Object { $_.COMPONENT })) { if ($r.COMPONENT) { $comps += ("{0}:{1}:{2}" -f (San $r.COMPONENT),(San $r.RELEASE),(San $r.EXTRELEASE)) } } } catch { }
        $compStr = ($comps -join ';')
        Write-Host ("SYSTEM: id={0} sid={1} client={2} reachable=YES release={3} comps=`"{4}`"" -f $p.id,$sid,$cli,$rel,$compStr)

        foreach ($nn in $noteList) {
            # downloaded? versions
            $head = @(Read-Rows $d 'CWBNTHEAD' "NUMM = '$nn'" @('NUMM','VERSNO','INCOMPLETE') 200 $null)
            $downloaded = ($head.Count -gt 0)
            $versions = @($head | ForEach-Object { $_.VERSNO } | Sort-Object -Unique)
            if (-not $downloaded) {
                Write-Host ("NOTE: sid={0}/{1} note={2} downloaded=NO versions=0 ntstatus= prstatus= verdict=UNKNOWN_NOT_DOWNLOADED confidence=D objects=0 mods=0 missing=0 flags= coverage=NO_OBJECT_DATA" -f $sid,$cli,$nn)
                $rowLines += (@($sid,$cli,$nn,'NO','0','','','UNKNOWN_NOT_DOWNLOADED','D','0','0','0','','NO_OBJECT_DATA','') -join "`t")
                continue
            }
            # customer status
            $cust = @(Read-Rows $d 'CWBNTCUST' "NUMM = '$nn'" @('NUMM','NTSTATUS','PRSTATUS','IMPL_PROGRESS') 5 $null)
            $nts=''; $prs=''
            if ($cust.Count) { $nts=$cust[0].NTSTATUS; $prs=$cust[0].PRSTATUS }
            $dec = Decode 'NTSTATUS' $nts
            $verdict = $dec.verdict; $conf = $dec.conf.Substring(0,1)
            # fixed-by-SP hint
            $fixed = @(Read-Rows $d 'CWBNTFIXED' "NUMM = '$nn'" @('NUMM','PAKID','ALEID') 20 $null)
            $flags = @()
            if ($fixed.Count -gt 0 -and $verdict -notin @('IMPLEMENTED')) { $flags += 'FIXED_BY_SP' }

            # collision check
            $objCount=0; $modHits=0; $missing=0; $cov='CHECKED'
            if (-not $NoCollisions) {
                # note -> correction instructions
                $ci = @(Read-Rows $d 'CWBNTCI' "NUMM = '$nn'" @('CIINSTA','CIPAKID','CIALEID','CIVERSNO') 2000 $null)
                $aleids = @($ci | ForEach-Object { $_.CIALEID } | Where-Object { $_ } | Sort-Object -Unique)
                $objs = @()   # {pgmid;object;objname;tobject;tobjname}
                if ($aleids.Count) {
                    for ($i=0; $i -lt $aleids.Count; $i += 80) {
                        $batch = @($aleids[$i..([Math]::Min($i+79,$aleids.Count-1))])
                        $co = @(Read-Rows $d 'CWBCIOBJ' '' @('ALEID','PGMID','OBJECT','OBJ_NAME','TRPGMID','TROBJECT','TROBJ_NAME') ($MaxObjects*2) @{ field='ALEID'; vals=$batch })
                        foreach ($o in $co) { $objs += ,([pscustomobject]@{ pgmid=(San $o.PGMID); object=(San $o.OBJECT); objname=(San $o.OBJ_NAME); trpgmid=(San $o.TRPGMID); tobject=(San $o.TROBJECT); tobjname=(San $o.TROBJ_NAME) }) }
                    }
                }
                # aggregate to TADIR (R3TR) object granularity so 4 LIMU includes of one
                # class count as ONE touched object (not four); keep a LIMU sample for detail.
                $matchNames = @{}
                $seenObj = @{}
                $uniqObjs = @()
                foreach ($o in $objs) {
                    # hasTad: only an R3TR transport object (TRPGMID='R3TR') has its own TADIR
                    # row; a LIMU sub-object (class include, method...) does NOT. Documentation /
                    # text object types (MTXT, DOCU/DOCT/DOCV, DSYS) are GUID-keyed and not
                    # meaningfully TADIR-tracked, so their absence is NOT an applicability signal.
                    $docTypes = @('MTXT','DOCT','DOCU','DOCV','DSYS','MESS')
                    $hasTad = ($o.trpgmid -eq 'R3TR' -and [bool]$o.tobjname -and ($docTypes -notcontains $o.tobject))
                    $tadName = if ($o.tobjname) { $o.tobjname } else { if ($o.objname.Length -gt 40) { $o.objname.Substring(0,40) } else { $o.objname } }
                    $tadType = if ($o.tobject) { $o.tobject } else { $o.object }
                    if (-not $tadName) { continue }
                    $key = "$tadType|$($tadName.ToUpper())"
                    if ($seenObj.ContainsKey($key)) { continue }
                    $seenObj[$key]=$true
                    $uniqObjs += ,([pscustomobject]@{ tadtype=$tadType; tadname=$tadName; limu="$($o.object):$($o.objname)"; hastad=$hasTad })
                    $matchNames[$tadName.ToUpper()] = $true
                }
                $objCount = $uniqObjs.Count
                if ($objCount -gt $MaxObjects) { $cov='COULD_NOT_CHECK'; $flags += "OBJECTS_TRUNCATED_$objCount" }
                $names = @($matchNames.Keys)
                # SMODILOG hits (customer-modified) by OBJ_NAME
                $modSet = @{}
                if ($names.Count -and $cov -eq 'CHECKED') {
                    for ($i=0; $i -lt $names.Count; $i += 60) {
                        $batch = @($names[$i..([Math]::Min($i+59,$names.Count-1))])
                        $sm = @(Read-Rows $d 'SMODILOG' '' @('OBJ_NAME','OBJ_TYPE','MOD_USER','MOD_DATE','TRKORR') 5000 @{ field='OBJ_NAME'; vals=$batch })
                        foreach ($m in $sm) { $modSet[(San $m.OBJ_NAME).ToUpper()] = @{ user=(San $m.MOD_USER); date=(San $m.MOD_DATE); tr=(San $m.TRKORR) } }
                    }
                }
                # TADIR existence by OBJ_NAME
                $tadSet = @{}
                if ($names.Count) {
                    for ($i=0; $i -lt $names.Count; $i += 60) {
                        $batch = @($names[$i..([Math]::Min($i+59,$names.Count-1))])
                        $td = @(Read-Rows $d 'TADIR' '' @('PGMID','OBJECT','OBJ_NAME','DEVCLASS','SRCSYSTEM') 5000 @{ field='OBJ_NAME'; vals=$batch })
                        foreach ($t in $td) { $tadSet[(San $t.OBJ_NAME).ToUpper()] = @{ devclass=(San $t.DEVCLASS); src=(San $t.SRCSYSTEM) } }
                    }
                }
                foreach ($o in $uniqObjs) {
                    $up = $o.tadname.ToUpper()
                    $inMod = $modSet.ContainsKey($up)
                    $inTad = $tadSet.ContainsKey($up)
                    if ($inMod) { $modHits++ }
                    if ($o.hastad -and -not $inTad) { $missing++ }
                    $tadCol = if ($inTad) { 'EXISTS' } elseif ($o.hastad) { 'MISSING' } else { 'N/A' }
                    $mu = if ($inMod) { $modSet[$up].user } else { '' }
                    $md = if ($inMod) { $modSet[$up].date } else { '' }
                    $dv = if ($inTad) { $tadSet[$up].devclass } else { '' }
                    $colLines += (@($sid,$cli,$nn,$o.tadtype,$o.tadname,$o.limu,$(if($inMod){'MOD'}else{''}),$tadCol,$dv,$mu,$md) -join "`t")
                }
                if ($modHits -gt 0) { $flags += "MOD_COLLISION_$modHits" }
                if ($missing -gt 0) { $flags += "OBJ_MISSING_$missing" }
            } else {
                $cov = 'NOT_CHECKED'
            }

            $flagStr = ($flags -join '|')
            Write-Host ("NOTE: sid={0}/{1} note={2} downloaded=YES versions={3} ntstatus={4} prstatus={5} verdict={6} confidence={7} objects={8} mods={9} missing={10} flags={11} coverage={12}" -f $sid,$cli,$nn,$versions.Count,$nts,$prs,$verdict,$conf,$objCount,$modHits,$missing,$flagStr,$cov)
            $rowLines += (@($sid,$cli,$nn,'YES',"$($versions.Count)",$nts,$prs,$verdict,$conf,"$objCount","$modHits","$missing",$flagStr,$cov,(JEsc $dec.label)) -join "`t")
        }
    } catch {
        Write-Host ("ERROR: sid={0} {1}" -f $p.system_name,(San $_.Exception.Message)); $partial = $true
    } finally { try { Disconnect-SapRfc } catch { } }
}

# ---- write TSVs --------------------------------------------------------------
$sbR = New-Object System.Text.StringBuilder
[void]$sbR.AppendLine(("sid`tclient`tnote`tdownloaded`tversions`tntstatus`tprstatus`tverdict`tconfidence`tobjects`tmods`tmissing`tflags`tcoverage`tstatus_label"))
foreach ($l in $rowLines) { [void]$sbR.AppendLine($l) }
[IO.File]::WriteAllText((Join-Path $OutDir 'note_status_rows.tsv'), $sbR.ToString(), (New-Object Text.UTF8Encoding($true)))

$sbC = New-Object System.Text.StringBuilder
[void]$sbC.AppendLine(("sid`tclient`tnote`tobj_type`tobj_name`tlimu_sample`tin_smodilog`ttadir`tdevclass`tmod_user`tmod_date"))
foreach ($l in $colLines) { [void]$sbC.AppendLine($l) }
[IO.File]::WriteAllText((Join-Path $OutDir 'collisions.tsv'), $sbC.ToString(), (New-Object Text.UTF8Encoding($true)))

$total = $rfcCapable.Count + $noPw.Count
$status = if ($reachable -eq 0) { 'ERROR' } elseif ($partial) { 'PARTIAL' } else { 'OK' }
Write-Host ("STATUS: {0} systems={1} reachable={2} notes={3}" -f $status,$total,$reachable,$noteList.Count)
if ($status -eq 'ERROR') { exit 2 } elseif ($status -eq 'PARTIAL') { exit 1 } else { exit 0 }
