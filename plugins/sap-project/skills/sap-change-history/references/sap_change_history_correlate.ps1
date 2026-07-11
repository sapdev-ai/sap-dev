# =============================================================================
# sap_change_history_correlate.ps1  -  offline correlation join for /sap-change-history
#
# Pure-local (NO SAP / RFC). Merges the decoded change timeline with the transport-import
# window (and, when present, /sap-diagnose evidence artifact timestamps) into ONE
# time-ordered event stream, so "TR imported at 14:00 -> field X changed at 14:05" reads as
# a single story. Emits correlate.tsv (source-tagged, time-sorted) + a one-line summary; the
# skill's Claude layer writes the narrative on top.
#
# Inputs (all optional except -OutTsv; each is a TSV this skill already produced):
#   -ChangesTsv <path>   columns incl. udate,utime,username,tcode,tabname,field,chngind,old,new
#   -ImportsTsv <path>   columns incl. trkorr/tr, as4date/date, as4time/time, as4user/user, status
#   -EvidenceTsv <path>  optional: ts,source,detail rows from Find-SapArtifacts (diagnose)
#   -WindowMinutes <n>   flag a change as import-adjacent when an import falls within +/- n min
#                        of it (default 60).
# Output: correlate.tsv (event_ts, source, actor, ref, detail, near_import) + CORRELATE: summary.
# =============================================================================

[CmdletBinding()]
param(
    [string] $ChangesTsv = '',
    [string] $ImportsTsv = '',
    [string] $EvidenceTsv = '',
    [Parameter(Mandatory)] [string] $OutTsv,
    [int]    $WindowMinutes = 60
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Read-Tsv([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return @() }
    $lines = @(Get-Content -LiteralPath $path | Where-Object { $_ -ne $null -and $_.Trim() -ne '' })
    if ($lines.Count -lt 2) { return @() }
    $hdr = @($lines[0] -split "`t" | ForEach-Object { $_.Trim().ToLower() })
    $out = New-Object System.Collections.ArrayList
    for ($i=1; $i -lt $lines.Count; $i++) {
        $f = $lines[$i] -split "`t"; $row=@{}
        for ($c=0; $c -lt $hdr.Count; $c++){ $row[$hdr[$c]] = if ($c -lt $f.Count) { $f[$c].Trim() } else { '' } }
        [void]$out.Add([pscustomobject]$row)
    }
    return @($out)
}
# normalize a (date=YYYYMMDD, time=HHMMSS|HH:MM:SS) into a sortable long + ISO-ish stamp
function Get-Stamp([string]$d,[string]$t) {
    $d = ($d -replace '[^0-9]',''); $t = ($t -replace '[^0-9]','')
    if ($d.Length -ne 8) { return @{ key=0; disp='' } }
    if ($t.Length -lt 6) { $t = ($t + '000000').Substring(0,6) }
    $key = [int64]($d + $t)
    $disp = $d.Substring(0,4)+'-'+$d.Substring(4,2)+'-'+$d.Substring(6,2)+' '+$t.Substring(0,2)+':'+$t.Substring(2,2)+':'+$t.Substring(4,2)
    return @{ key=$key; disp=$disp }
}
function Col($row,[string[]]$names){ foreach ($n in $names){ if ($row.PSObject.Properties.Name -contains $n -and "$($row.$n)".Trim()) { return "$($row.$n)".Trim() } } return '' }

$events = New-Object System.Collections.ArrayList

foreach ($r in (Read-Tsv $ChangesTsv)) {
    $st = Get-Stamp (Col $r @('udate','date')) (Col $r @('utime','time'))
    $fld = Col $r @('field','fname'); $old = Col $r @('old','f_old'); $new = Col $r @('new','f_new')
    $tab = Col $r @('tabname','tab')
    $detail = if ($fld) { "${tab}-${fld}: '$old' -> '$new'" } else { "$tab ($(Col $r @('chngind','ind')))" }
    [void]$events.Add([pscustomobject]@{ key=$st.key; ts=$st.disp; source='change'; actor=(Col $r @('username','user')); ref=(Col $r @('nr','changenr')); detail=$detail; near='' })
}
$imports = @()
foreach ($r in (Read-Tsv $ImportsTsv)) {
    $st = Get-Stamp (Col $r @('as4date','date')) (Col $r @('as4time','time'))
    $imports += $st.key
    [void]$events.Add([pscustomobject]@{ key=$st.key; ts=$st.disp; source='import'; actor=(Col $r @('as4user','user')); ref=(Col $r @('trkorr','tr')); detail=("transport "+(Col $r @('status'))); near='' })
}
foreach ($r in (Read-Tsv $EvidenceTsv)) {
    $ts = Col $r @('ts','timestamp'); $k=0; [void][int64]::TryParse(($ts -replace '[^0-9]',''), [ref]$k)
    [void]$events.Add([pscustomobject]@{ key=$k; ts=$ts; source='evidence'; actor=(Col $r @('source','skill')); ref=(Col $r @('kind','ref')); detail=(Col $r @('detail')); near='' })
}

# flag import-adjacency on change events
$win = [int64]$WindowMinutes * 100   # HHMMSS delta approx (minutes*100 covers MMSS band; coarse by design)
$adj = 0
foreach ($e in $events) {
    if ($e.source -ne 'change' -or $e.key -eq 0) { continue }
    foreach ($ik in $imports) { if ($ik -ne 0 -and [math]::Abs($e.key - $ik) -le $win) { $e.near='Y'; $adj++; break } }
}

$sorted = @($events | Sort-Object key)
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("event_ts`tsource`tactor`tref`tdetail`tnear_import")
foreach ($e in $sorted) { [void]$sb.AppendLine(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f $e.ts,$e.source,$e.actor,$e.ref,($e.detail -replace "`t",' '),$e.near)) }
[System.IO.File]::WriteAllText($OutTsv, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))

$nc = @($sorted | Where-Object { $_.source -eq 'change' }).Count
$ni = @($sorted | Where-Object { $_.source -eq 'import' }).Count
$ne = @($sorted | Where-Object { $_.source -eq 'evidence' }).Count
Write-Host ("CORRELATE: events={0} changes={1} imports={2} evidence={3} import_adjacent_changes={4} out={5}" -f $sorted.Count,$nc,$ni,$ne,$adj,$OutTsv)
Write-Host "STATUS: OK"
