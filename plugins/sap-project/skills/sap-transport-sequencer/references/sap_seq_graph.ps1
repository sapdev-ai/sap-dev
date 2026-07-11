# =============================================================================
# sap_seq_graph.ps1  -  offline import-order + conflict graph for /sap-transport-sequencer
#
# Pure-local (no SAP / no RFC). Reads the TSVs sap_seq_read.ps1 wrote and computes a
# safe import order plus the conflict set. Nodes = TRs; an edge A->B exists when they
# share >=1 normalized object AND release(A) < release(B) -- a DAG by construction, so
# a stable sort by (release_ts, trkorr) already satisfies every edge. Unreleased TRs
# are never merged into the order (trailing NOT_IMPORTABLE section).
#
#   -InDir <dir with headers.tsv/objects.tsv/overlaps.tsv/tasks.tsv> -OutDir <dir>
#
# Conflicts (finding vocabulary): OVERLAP, SAME_TIMESTAMP, UNRELEASED,
# MISSING_PREDECESSOR, OVERTAKER_RISK.
#
# stdout:
#   SEQ: pos=<n> tr=<..> ts=<..> constrained_by=<trs|-> flags=<..>
#   CONFLICT: sev=<..> cat=<..> tr=<..> detail="<..>"
#   STATUS: OK ordered=<n> unimportable=<n> conflicts=<n>
# Exit: 0.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $InDir,
    [Parameter(Mandatory)][string] $OutDir
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RS = [char]0x241E
function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Read-Tsv { param([string]$p)
    if (-not (Test-Path $p)) { return @() }
    $txt = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
    $lines = $txt -split "`r`n|`n|`r" | Where-Object { $_ -ne '' }
    if ($lines.Count -lt 1) { return @() }
    $hdr = $lines[0] -split "`t"; $out = @()
    for ($i=1; $i -lt $lines.Count; $i++) { $c = $lines[$i] -split "`t"; $r = [ordered]@{}; for ($j=0;$j -lt $hdr.Count;$j++){ $r[$hdr[$j]] = if ($j -lt $c.Count) { $c[$j] } else { '' } }; $out += ,([pscustomobject]$r) }
    return $out
}
function Write-Tsv { param([string]$Path,[string]$Header,[object[]]$Lines)
    $sb = New-Object System.Text.StringBuilder; [void]$sb.AppendLine($Header)
    foreach ($l in $Lines) { [void]$sb.AppendLine($l) }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}

if ($MyInvocation.InvocationName -eq '.') { return }

# NB: PowerShell variable names are CASE-INSENSITIVE, so `foreach ($h in $H)` makes the
# iterator and the collection the SAME variable -- after the loop $H is clobbered to the
# last element. Every loop below uses a distinct iterator name (row/obj/ov) to avoid it.
$Headers   = Read-Tsv (Join-Path $InDir 'headers.tsv')
$Objects   = Read-Tsv (Join-Path $InDir 'objects.tsv')
$Overlaps  = Read-Tsv (Join-Path $InDir 'overlaps.tsv')
$Tasks     = Read-Tsv (Join-Path $InDir 'tasks.tsv')

# index
$hdr = @{}; foreach ($row in $Headers) { $hdr[$row.trkorr] = $row }
$objByTr = @{}; $trByObj = @{}
foreach ($obj in $Objects) {
    $nk = $obj.norm_object + ':' + $obj.norm_name
    if (-not $objByTr.ContainsKey($obj.trkorr)) { $objByTr[$obj.trkorr] = New-Object System.Collections.Generic.HashSet[string] }
    [void]$objByTr[$obj.trkorr].Add($nk)
    if (-not $trByObj.ContainsKey($nk)) { $trByObj[$nk] = New-Object System.Collections.Generic.HashSet[string] }
    [void]$trByObj[$nk].Add($obj.trkorr)
}

$released   = @($Headers | Where-Object { $_.released -eq 'Y' } | Sort-Object @{e={$_.release_ts}}, @{e={$_.trkorr}})
$unreleased = @($Headers | Where-Object { $_.released -ne 'Y' })

# ---- ordered sequence + constrained_by ---------------------------------------
$seqLines = @(); $pos = 0
foreach ($h in $released) {
    $pos++
    $mine = $objByTr[$h.trkorr]
    $cons = @()
    if ($mine) { foreach ($p in $released) { if ($p.trkorr -eq $h.trkorr) { break }; $pm = $objByTr[$p.trkorr]; if ($pm) { foreach ($x in $mine) { if ($pm.Contains($x)) { $cons += $p.trkorr; break } } } } }
    $flags = @(); if ($h.trfunction -eq 'T') { $flags += 'TRANSPORT_OF_COPIES' }
    $seqLines += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $pos,$h.trkorr,$h.release_ts,(San $h.as4user),(San $h.text),$(if($cons.Count){$cons -join ','}else{'-'}),$(if($flags.Count){$flags -join ','}else{'-'}))
    Write-Host ("SEQ: pos={0} tr={1} ts={2} constrained_by={3} flags={4}" -f $pos,$h.trkorr,$h.release_ts,$(if($cons.Count){$cons -join ','}else{'-'}),$(if($flags.Count){$flags -join ','}else{'-'}))
}
foreach ($h in $unreleased) {
    $seqLines += ("NOT_IMPORTABLE`t{0}`t{1}`t{2}`t{3}`t-`tUNRELEASED" -f $h.trkorr,$h.release_ts,(San $h.as4user),(San $h.text))
}
Write-Tsv (Join-Path $OutDir 'sequence.tsv') "position`ttrkorr`trelease_ts`towner`tdescription`tconstrained_by`tflags" $seqLines

# ---- conflicts ---------------------------------------------------------------
$conf = @()
function AddConf { param($sev,$cat,$tr,$related,$objs,$cov,$detail)
    $script:conf += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $sev,$cat,$tr,$related,$objs,$cov,(San $detail))
    Write-Host ("CONFLICT: sev={0} cat={1} tr={2} detail=`"{3}`"" -f $sev,$cat,$tr,((San $detail) -replace '"',"'"))
}

# OVERLAP / SAME_TIMESTAMP between listed released pairs sharing an object
for ($i=0; $i -lt $released.Count; $i++) {
    for ($j=$i+1; $j -lt $released.Count; $j++) {
        $a=$released[$i]; $b=$released[$j]
        $am=$objByTr[$a.trkorr]; $bm=$objByTr[$b.trkorr]; if (-not $am -or -not $bm) { continue }
        $shared = @(); foreach ($x in $am) { if ($bm.Contains($x)) { $shared += $x } }
        if ($shared.Count) {
            $sameTs = ($a.release_ts -eq $b.release_ts)
            $sev = if ($sameTs) { 'HIGH' } else { 'MEDIUM' }
            $cat = if ($sameTs) { 'SAME_TIMESTAMP' } else { 'OVERLAP' }
            $d = if ($sameTs) { "$($a.trkorr) and $($b.trkorr) share $($shared.Count) object(s) AND released at the SAME timestamp $($a.release_ts) -- order is ambiguous at date/time granularity; verify manually" } else { "$($b.trkorr) must import after $($a.trkorr): both touch $($shared -join ', ')" }
            AddConf $sev $cat $b.trkorr $a.trkorr ($shared -join ',') 'CHECKED' $d
        }
    }
}
# UNRELEASED listed TRs
foreach ($h in $unreleased) { AddConf 'HIGH' 'UNRELEASED' $h.trkorr '-' '-' 'CHECKED' "$($h.trkorr) is not released (status $($h.trstatus)) -- it cannot be imported; release it first or remove it from the set" }
# unreleased tasks under a released header
foreach ($t in $Tasks) { AddConf 'MEDIUM' 'UNRELEASED' $t.parent_trkorr $t.task '-' 'CHECKED' "task $($t.task) (status $($t.task_status), $($t.user)) under released $($t.parent_trkorr) is still open -- its changes are NOT in the request" }
# reverse-scan: one conflict per external TR -- OVERTAKER_RISK (still modifiable) or
# MISSING_PREDECESSOR (released immediately before a listed TR, not in the set)
foreach ($ov in $Overlaps) {
    $etr = $ov.ext_trkorr; $est = $ov.ext_status; $ets = $ov.ext_ts; $shared = $ov.shared_objs; $minTs = $ov.min_listed_ts
    $objDisp = ($shared -replace '\|',', ')
    $modifiable = ($est -ne 'R' -and $est -ne 'O')
    if ($modifiable) {
        AddConf 'HIGH' 'OVERTAKER_RISK' $etr '-' $shared 'CHECKED' "$etr is still modifiable (status $est, $($ov.ext_user)) and touches $objDisp which is in this set -- if released after the import it will OVERTAKE and can regress the change"
    } elseif ($ets -and $minTs -and ($ets -lt $minTs)) {
        AddConf 'HIGH' 'MISSING_PREDECESSOR' $etr '-' $shared 'CHECKED' "$etr (released $ets, $($ov.ext_user)) touches $objDisp just before the listed TR(s) but is NOT in the set -- likely a missing predecessor; import it first or confirm it is already in the target"
    }
}
Write-Tsv (Join-Path $OutDir 'conflicts.tsv') "severity`tcategory`ttrkorr`trelated`tobjects`tcoverage`tdetail" $conf

Write-Host ("STATUS: OK ordered=$($released.Count) unimportable=$($unreleased.Count) conflicts=$($conf.Count)")
exit 0
