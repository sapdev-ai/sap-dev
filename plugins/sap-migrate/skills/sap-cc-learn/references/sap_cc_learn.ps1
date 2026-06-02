# sap-cc-learn helper -- knowledge-pack flywheel (OFFLINE)
#
# Learns real ATC message ids from a triaged campaign and feeds them back into
# catalog.tsv's detect_message_ids, so future triage matches by message id (the
# highest-precedence, most reliable basis) and the UNMATCHED ratio drops.
#
# Two safe sources of new message ids:
#   1. AUTO  -- a message id seen ONLY on findings that matched a single pattern
#               (via simpl-item/regex) is safe to bind to that pattern. A message
#               id seen across MULTIPLE patterns is AMBIGUOUS and is skipped.
#   2. ASSIGN-- the operator classifies UNMATCHED message ids to a pattern via an
#               assign file (message_id<TAB>pattern_id); apply merges those too.
#
# Actions:
#   propose (default) -- report ADD candidates + AMBIGUOUS + ranked UNMATCHED;
#                        write findings\learn_proposal.md. No writes to the pack.
#   apply             -- merge AUTO candidates (+ -AssignFile rows) into the
#                        target catalog.tsv (real TABs, UTF-8 no BOM).
#
# Params:
#   -Action <propose|apply>  (default propose)
#   -CampaignDir <dir>       (required) reads findings\findings_triaged.tsv
#   -KnowledgeDir <dir>      catalog to read/update (default: the plugin pack;
#                            for apply, prefer your override {custom_url}\knowledge
#                            so learned ids survive plugin updates)
#   -AssignFile <path>       (apply) TSV: message_id<TAB>pattern_id (operator
#                            classifications of UNMATCHED ids)
#   -TopUnmatched <int>      cap UNMATCHED lines (default 20)
#
# Output grammar:
#   ADD: pattern=<P> message_id=<M>
#   AMBIGUOUS: message_id=<M> patterns=<P1,P2>
#   UNMATCHED: message_id=<M> count=<n> sample=<text>
#   LEARN: add=<n> ambiguous=<n> unmatched_ids=<n> proposal=<path>
#   APPLIED: patterns_updated=<n> message_ids_added=<n> file=<path>
#   STATUS: OK | EMPTY | ERROR
# Exit: 0 ok | 1 empty (no findings) | 2 error

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('propose','apply')][string]$Action,
    [Parameter(Mandatory)][string]$CampaignDir,
    [string]$KnowledgeDir = '',
    [string]$AssignFile = '',
    [int]$TopUnmatched = 20
)

$ErrorActionPreference = 'Stop'
# PS 5.1 Get-Content defaults to ANSI; force UTF-8 for the catalog + findings.
$PSDefaultParameterValues['Get-Content:Encoding'] = 'UTF8'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Utf8NoBom([string]$Path,[string]$Text){
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Text,$enc)
}
function Field($arr,[int]$i){ if ($i -ge 0 -and $i -lt $arr.Length) { return [string]$arr[$i] } else { return '' } }
function Cell($f,$idx,[string]$name){ if ($idx.ContainsKey($name)) { return (Field $f $idx[$name]).Trim() } else { return '' } }
function CsvSet([string]$s){ $h=@(); if ($s){ foreach($t in $s.Split(',')){ $tt=$t.Trim(); if($tt){ $h += $tt } } }; return $h }

if ([string]::IsNullOrWhiteSpace($KnowledgeDir)) {
    $KnowledgeDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'shared\knowledge'
}
$catalogPath = Join-Path $KnowledgeDir 'catalog.tsv'
if (-not (Test-Path -LiteralPath $catalogPath)) { Write-Output "ERROR: catalog not found at $catalogPath"; Write-Output 'STATUS: ERROR'; exit 2 }
$triagedPath = Join-Path $CampaignDir 'findings\findings_triaged.tsv'
if (-not (Test-Path -LiteralPath $triagedPath)) { Write-Output 'ERROR: findings_triaged.tsv missing -- run /sap-cc-triage first'; Write-Output 'STATUS: EMPTY'; exit 1 }

try {
    # --- load catalog: pattern_id -> { detect set }, and remember valid patterns ---
    $catAll = @(Get-Content -LiteralPath $catalogPath)
    if ($catAll.Count -lt 2) { Write-Output 'ERROR: catalog has no rows'; Write-Output 'STATUS: ERROR'; exit 2 }
    $cHdr = @($catAll[0].Split("`t") | ForEach-Object { $_.Trim() }); $ci = @{}; for ($i=0;$i -lt $cHdr.Count;$i++){ $ci[$cHdr[$i]] = $i }
    if (-not ($ci.ContainsKey('pattern_id') -and $ci.ContainsKey('detect_message_ids'))) { Write-Output 'ERROR: catalog missing pattern_id / detect_message_ids columns'; Write-Output 'STATUS: ERROR'; exit 2 }
    $catDetect = @{}; $validPat = @{}
    for ($i=1;$i -lt $catAll.Count;$i++){ if (-not $catAll[$i].Trim()){ continue }; $f=$catAll[$i].Split("`t"); $p=(Field $f $ci['pattern_id']).Trim(); if(-not $p){continue}
        $validPat[$p]=$true
        $set=@{}; foreach($m in (CsvSet (Field $f $ci['detect_message_ids']))){ $set[$m]=$true }; $catDetect[$p]=$set
    }

    # --- load triaged findings ---
    $tAll = @(Get-Content -LiteralPath $triagedPath)
    if ($tAll.Count -lt 2) { Write-Output 'ERROR: findings_triaged.tsv has no rows'; Write-Output 'STATUS: EMPTY'; exit 1 }
    $tHdr = @($tAll[0].Split("`t") | ForEach-Object { $_.Trim() }); $ti=@{}; for ($i=0;$i -lt $tHdr.Count;$i++){ $ti[$tHdr[$i]]=$i }

    $msgidToPatterns = @{}   # msgid -> hashtable of patterns (matched findings)
    $unmatched = @{}         # msgid -> @{count; sample}
    for ($i=1;$i -lt $tAll.Count;$i++){
        $ln=$tAll[$i]; if(-not $ln.Trim()){continue}; $f=$ln.Split("`t")
        $mid=(Cell $f $ti 'message_id'); $pat=(Cell $f $ti 'pattern'); $msg=(Cell $f $ti 'message_text')
        if ($pat -and $pat -ne 'UNMATCHED') {
            if ($mid) { if(-not $msgidToPatterns.ContainsKey($mid)){ $msgidToPatterns[$mid]=@{} }; $msgidToPatterns[$mid][$pat]=$true }
        } elseif ($pat -eq 'UNMATCHED') {
            $key = if ($mid) { $mid } else { '(no-message-id)' }
            if (-not $unmatched.ContainsKey($key)) { $unmatched[$key]=@{ count=0; sample=$msg } }
            $unmatched[$key].count++
        }
    }

    # --- classify AUTO add candidates vs ambiguous ---
    $addCand = @{}    # pattern -> hashtable of new msgids
    $ambiguous = @()
    foreach ($mid in $msgidToPatterns.Keys) {
        $pats = @($msgidToPatterns[$mid].Keys)
        if ($pats.Count -eq 1) {
            $p = $pats[0]
            $already = ($catDetect.ContainsKey($p) -and $catDetect[$p].ContainsKey($mid))
            if (-not $already) { if(-not $addCand.ContainsKey($p)){ $addCand[$p]=@{} }; $addCand[$p][$mid]=$true }
        } else {
            $ambiguous += [pscustomobject]@{ mid=$mid; patterns=($pats -join ',') }
        }
    }

    # --- emit report (both actions) ---
    $addCount = 0
    foreach ($p in ($addCand.Keys | Sort-Object)) { foreach ($m in ($addCand[$p].Keys | Sort-Object)) { Write-Output "ADD: pattern=$p message_id=$m"; $addCount++ } }
    foreach ($a in ($ambiguous | Sort-Object mid)) { Write-Output "AMBIGUOUS: message_id=$($a.mid) patterns=$($a.patterns)" }
    $umRanked = @($unmatched.GetEnumerator() | Sort-Object { $_.Value.count } -Descending)
    $shown = 0
    foreach ($u in $umRanked) { if ($shown -ge $TopUnmatched) { break }; Write-Output "UNMATCHED: message_id=$($u.Key) count=$($u.Value.count) sample=$($u.Value.sample)"; $shown++ }

    # --- proposal markdown (an editable basis for the assign file) ---
    $prop = New-Object System.Collections.Generic.List[string]
    $prop.Add("# Knowledge-pack learn proposal"); $prop.Add("")
    $prop.Add("## Auto-add (message id -> single matched pattern; safe)")
    $prop.Add("| pattern_id | message_id |"); $prop.Add("|---|---|")
    foreach ($p in ($addCand.Keys | Sort-Object)) { foreach ($m in ($addCand[$p].Keys | Sort-Object)) { $prop.Add("| $p | $m |") } }
    $prop.Add(""); $prop.Add("## Ambiguous (seen on >1 pattern; NOT added)")
    $prop.Add("| message_id | patterns |"); $prop.Add("|---|---|")
    foreach ($a in ($ambiguous | Sort-Object mid)) { $prop.Add("| $($a.mid) | $($a.patterns) |") }
    $prop.Add(""); $prop.Add("## Unmatched message ids -- classify these (fill assign_to_pattern, then feed as the -AssignFile)")
    $prop.Add("| message_id | count | assign_to_pattern | sample |"); $prop.Add("|---|---|---|---|")
    foreach ($u in $umRanked) { $prop.Add("| $($u.Key) | $($u.Value.count) |  | $($u.Value.sample) |") }
    $proposalPath = Join-Path $CampaignDir 'findings\learn_proposal.md'
    Write-Utf8NoBom $proposalPath (($prop -join "`r`n") + "`r`n")

    Write-Output "LEARN: add=$addCount ambiguous=$($ambiguous.Count) unmatched_ids=$($unmatched.Count) proposal=$proposalPath"

    if ($Action -eq 'propose') { Write-Output 'STATUS: OK'; exit 0 }

    # --- apply: merge AUTO candidates + -AssignFile into the catalog ---
    # operator assignments (message_id -> pattern_id) for UNMATCHED ids
    if ($AssignFile) {
        if (-not (Test-Path -LiteralPath $AssignFile)) { Write-Output "ERROR: -AssignFile not found: $AssignFile"; Write-Output 'STATUS: ERROR'; exit 2 }
        $aAll = @(Get-Content -LiteralPath $AssignFile)
        $aStart = 0
        if ($aAll.Count -gt 0) { $h0 = $aAll[0].Split("`t"); if ((Field $h0 0).Trim().ToLower() -eq 'message_id') { $aStart = 1 } }
        for ($i=$aStart;$i -lt $aAll.Count;$i++){
            $ln=$aAll[$i]; if(-not $ln.Trim()){continue}; $f=$ln.Split("`t")
            $m=(Field $f 0).Trim(); $p=(Field $f 1).Trim()
            if (-not $m -or -not $p) { continue }
            if (-not $validPat.ContainsKey($p)) { Write-Output "WARN: assign skipped -- unknown pattern_id '$p' for message_id '$m'"; continue }
            if ($catDetect.ContainsKey($p) -and $catDetect[$p].ContainsKey($m)) { continue }
            if (-not $addCand.ContainsKey($p)){ $addCand[$p]=@{} }; $addCand[$p][$m]=$true
        }
    }

    if ($addCand.Count -eq 0) { Write-Output "APPLIED: patterns_updated=0 message_ids_added=0 file=$catalogPath"; Write-Output 'STATUS: OK'; exit 0 }

    # rewrite catalog.tsv: only the detect_message_ids cell of affected patterns changes
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add(($cHdr -join "`t"))
    $patUpd = 0; $idsAdded = 0
    for ($i=1;$i -lt $catAll.Count;$i++){
        if (-not $catAll[$i].Trim()) { continue }
        $f = $catAll[$i].Split("`t")
        $p = (Field $f $ci['pattern_id']).Trim()
        if ($addCand.ContainsKey($p)) {
            $existing = @(CsvSet (Field $f $ci['detect_message_ids']))
            $have = @{}; foreach($m in $existing){ $have[$m]=$true }
            $added = 0
            foreach ($m in ($addCand[$p].Keys | Sort-Object)) { if (-not $have.ContainsKey($m)) { $existing += $m; $have[$m]=$true; $added++ } }
            if ($added -gt 0) { $f[$ci['detect_message_ids']] = ($existing -join ','); $patUpd++; $idsAdded += $added }
        }
        $out.Add(($f -join "`t"))
    }
    Write-Utf8NoBom $catalogPath (($out -join "`r`n") + "`r`n")
    Write-Output "APPLIED: patterns_updated=$patUpd message_ids_added=$idsAdded file=$catalogPath"
    Write-Output "NOTE: applied to $catalogPath -- if this is the shipped plugin pack, prefer an override at {custom_url}\knowledge so learned ids survive plugin updates."
    Write-Output 'STATUS: OK'
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output 'STATUS: ERROR'
    exit 2
}
