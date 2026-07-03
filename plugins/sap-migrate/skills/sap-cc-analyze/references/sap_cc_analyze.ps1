# sap-cc-analyze helper -- S/4 readiness ATC orchestration spine (OFFLINE)
#
# Two deterministic, file-only actions (no SAP/RFC/GUI here -- the ATC run
# itself is delegated to /sap-atc, invoked with --variant=S4HANA_READINESS so
# the readiness variant runs; /sap-atc fails loud when it cannot set that
# variant). Alternatively run the readiness ATC manually and ingest its
# per-finding export here:
#
#   prepare : scope.tsv -> findings\analyze_worklist.tsv (REMEDIATE objects
#             still in SCOPED state), optionally capped by -Limit. This is the
#             list the orchestrator loops /sap-atc over.
#   ingest  : parse ATC result file(s) -> findings\findings_raw.tsv (append +
#             dedupe), then advance state.tsv SCOPED -> ANALYZED only for
#             objects the ingested evidence covers: a finding row, or a
#             checked-object row (all finding columns blank -- coverage
#             evidence only, never appended as a finding). Worklist objects
#             with no evidence keep their prior state and are counted on the
#             INFO: line, so a partially-run ATC loop can never record unrun
#             objects as analyzed-clean.
#
# The ingest parser is header-alias tolerant: it maps common ATC export column
# names onto the canonical findings schema; unmapped canonical columns are left
# blank (so /sap-atc output and manual "Manage Results" exports both work).
#
# Params:
#   -Action <prepare|ingest>   (required)
#   -CampaignDir <dir>         (required)
#   -ResultsPath <file|dir>    (ingest) one ATC export, or a folder of them
#   -Limit <int>               (prepare) cap worklist size (0 = all)
#
# Output grammar (parseable):
#   WORKLIST: total=<n> file=<path>
#   FINDINGS: total=<n> new=<n> objects_with_findings=<n> file=<path>
#   PRIORITY: <p> | COUNT: <n>
#   ANALYZED: <n>
#   INFO: <n> of <m> worklist objects not covered by this ingest
#   STATUS: OK | EMPTY | ERROR
# Exit: 0 ok | 1 empty (nothing to do) | 2 error

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('prepare','ingest')][string]$Action,
    [Parameter(Mandatory)][string]$CampaignDir,
    [string]$ResultsPath = '',
    [int]$Limit = 0,
    # A5 batched ATC: when > 0, `prepare` ALSO chunks the worklist into
    # object-list files of <= BatchSize objects each (findings\atc_raw\batches\
    # analyze_batch_<nnn>.tsv, one "<ATC_TYPE> <OBJ_NAME>" line per object) that
    # the orchestrator feeds to `/sap-atc --object-list`. 0 = per-object (legacy).
    [int]$BatchSize = 0
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 Get-Content defaults to ANSI; force UTF-8 so ATC result
# exports with non-ASCII (e.g. localized) message text read correctly.
$PSDefaultParameterValues['Get-Content:Encoding'] = 'UTF8'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Utf8NoBom([string]$Path,[string]$Text){
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Text,$enc)
}
function Field($arr,[int]$i){ if ($i -lt $arr.Length) { return [string]$arr[$i] } else { return '' } }
function Norm([string]$s){ return ($s -replace '[^A-Za-z0-9]','').ToLower() }

# Map a repository (TADIR) object type to the /sap-atc SCI Object-Set vocabulary
# (PROGRAM/CLASS/INTERFACE/FUGR/DDIC/TYPEGROUP/WDYN). Returns '' for types
# /sap-atc has no Object-Set category for (DEVC, MSAG, bare FUNC, ...) so the
# caller can skip them instead of feeding /sap-atc a token it will reject.
# DDIC sub-kinds (DOMA/DTEL/TABL/VIEW/...) all map to the single DDIC category;
# whether /sap-atc resolves a given DDIC sub-kind is release-dependent.
function To-AtcType([string]$t){
    switch (($t).Trim().ToUpper()) {
        'PROG'      { 'PROGRAM' }
        'CLAS'      { 'CLASS' }
        'INTF'      { 'INTERFACE' }
        'FUGR'      { 'FUGR' }
        'TABL'      { 'DDIC' }
        'VIEW'      { 'DDIC' }
        'DOMA'      { 'DDIC' }
        'DTEL'      { 'DDIC' }
        'SHLP'      { 'DDIC' }
        'ENQU'      { 'DDIC' }
        'TTYP'      { 'DDIC' }
        'TYPE'      { 'TYPEGROUP' }
        'WDYN'      { 'WDYN' }
        'WDYA'      { 'WDYN' }
        default     { '' }
    }
}

function Read-Tsv([string]$path){
    # Generic tab/comma reader -> @{ headers=@(orig); rows=@(@(cells)) }
    $out = @{ headers = @(); rows = @() }
    if (-not (Test-Path -LiteralPath $path)) { return $out }
    $lines = @(Get-Content -LiteralPath $path)
    if ($lines.Count -eq 0) { return $out }
    $delim = if ($lines[0].Contains("`t")) { "`t" } elseif ($lines[0].Contains(',')) { ',' } else { "`t" }
    $out.headers = @($lines[0].Split($delim) | ForEach-Object { $_.Trim() })
    for ($i = 1; $i -lt $lines.Count; $i++){
        if (-not $lines[$i].Trim()) { continue }
        $out.rows += ,@($lines[$i].Split($delim))
    }
    return $out
}

function Read-StateRows([string]$path){
    $rows = @()
    if (-not (Test-Path -LiteralPath $path)) { return $rows }
    $all = @(Get-Content -LiteralPath $path)
    if ($all.Count -lt 2) { return $rows }
    for ($i = 1; $i -lt $all.Count; $i++){
        $ln = $all[$i]; if (-not $ln.Trim()) { continue }
        $f = $ln.Split("`t")
        $rows += [pscustomobject]@{
            obj_name = (Field $f 0); obj_type = (Field $f 1); state = (Field $f 2)
            tier = $(if ((Field $f 3)) { (Field $f 3) } else { '-' })
            decision = $(if ((Field $f 4)) { (Field $f 4) } else { '-' })
            updated_on = (Field $f 5)
        }
    }
    return $rows
}
function Write-StateRows([string]$path,$rows){
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("obj_name`tobj_type`tstate`ttier`tdecision`tupdated_on")
    foreach ($r in $rows) { $L.Add("$($r.obj_name)`t$($r.obj_type)`t$($r.state)`t$($r.tier)`t$($r.decision)`t$($r.updated_on)") }
    Write-Utf8NoBom $path (($L -join "`r`n") + "`r`n")
}

# Canonical findings schema + header aliases (normalized).
$CANON = @(
    @{ n='obj_name';            a=@('objname','object','objectname','obj','name') },
    @{ n='obj_type';            a=@('objtype','type','objecttype','kind') },
    @{ n='check_id';            a=@('checkid','check','checkname','scicheck','checktitle') },
    @{ n='priority';            a=@('priority','prio','prty','prioritynumber') },
    @{ n='line';                a=@('line','lineno','linenumber','row','codeline') },
    @{ n='message_id';          a=@('messageid','msgid','msgno','findingid','code','checkmessageid') },
    @{ n='message_text';        a=@('messagetext','msgtext','msgtxt','msg','message','text','description','findingtext','checkmessage') },
    @{ n='simplification_item'; a=@('simplificationitem','simplitem','simplification','si','siid','category') },
    @{ n='sap_note';            a=@('sapnote','note','notenumber','oss','noteid') }
)
$CANON_ORDER = @('obj_name','obj_type','check_id','priority','line','message_id','message_text','simplification_item','sap_note')

if (-not (Test-Path -LiteralPath (Join-Path $CampaignDir 'campaign.json'))) {
    Write-Output "ERROR: campaign workspace not found at $CampaignDir (run /sap-cc-campaign init)"; Write-Output 'STATUS: ERROR'; exit 2
}
$findingsDir = Join-Path $CampaignDir 'findings'
if (-not (Test-Path -LiteralPath $findingsDir)) { New-Item -ItemType Directory -Force -Path $findingsDir | Out-Null }
$statePath = Join-Path $CampaignDir 'state.tsv'

try {
    if ($Action -eq 'prepare') {
        $scope = Read-Tsv (Join-Path $CampaignDir 'scope.tsv')
        if ($scope.rows.Count -eq 0) { Write-Output 'ERROR: scope.tsv empty or missing -- run /sap-cc-usage first'; Write-Output 'STATUS: EMPTY'; exit 1 }
        # column indexes by header
        $hi = @{}; for ($i = 0; $i -lt $scope.headers.Count; $i++){ $hi[(Norm $scope.headers[$i])] = $i }
        $iName = $hi['objname']; $iType = $hi['objtype']; $iDec = $hi['decision']
        # current states (to skip already-analyzed)
        $stateByKey = @{}
        foreach ($r in (Read-StateRows $statePath)) { $stateByKey["$($r.obj_name)|$($r.obj_type)"] = $r.state }

        $work = New-Object System.Collections.Generic.List[string]
        $work.Add("obj_name`tobj_type`tatc_type")
        $skip = New-Object System.Collections.Generic.List[string]
        $skip.Add("obj_name`tobj_type`treason")
        $pairs = New-Object System.Collections.Generic.List[object]   # @(atc_type, obj_name) for batching
        $count = 0; $nSkip = 0
        foreach ($row in $scope.rows){
            $nm = (Field $row $iName).Trim(); $ty = (Field $row $iType).Trim(); $dec = (Field $row $iDec).Trim()
            if ($dec -ne 'REMEDIATE') { continue }
            $st = $stateByKey["$nm|$ty"]
            if ($st -and $st -ne 'SCOPED') { continue }   # only objects not yet analyzed
            $atc = To-AtcType $ty
            if (-not $atc) {
                # /sap-atc has no SCI Object-Set category for this type (DEVC, MSAG,
                # bare FUNC, ...). Record it but keep it OUT of the ATC worklist so
                # ingest never falsely advances it to ANALYZED.
                $skip.Add("$nm`t$ty`tno_atc_category"); $nSkip++
                continue
            }
            $work.Add("$nm`t$ty`t$atc")
            $pairs.Add(@($atc, $nm))
            $count++
            if ($Limit -gt 0 -and $count -ge $Limit) { break }
        }
        $wlPath = Join-Path $findingsDir 'analyze_worklist.tsv'
        Write-Utf8NoBom $wlPath (($work -join "`r`n") + "`r`n")
        $skipPath = Join-Path $findingsDir 'analyze_skipped.tsv'
        Write-Utf8NoBom $skipPath (($skip -join "`r`n") + "`r`n")
        Write-Output "WORKLIST: total=$count file=$wlPath"
        Write-Output "SKIPPED: total=$nSkip file=$skipPath"

        # A5: chunk the worklist into /sap-atc --object-list batch files.
        if ($BatchSize -gt 0 -and $count -gt 0) {
            $batchDir = Join-Path $findingsDir 'atc_raw\batches'
            if (Test-Path -LiteralPath $batchDir) {
                # clear stale batch files so a re-prepare doesn't leave orphans
                Get-ChildItem -LiteralPath $batchDir -Filter 'analyze_batch_*.tsv' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            } else {
                New-Item -ItemType Directory -Force -Path $batchDir | Out-Null
            }
            $nBatch = 0
            for ($b = 0; $b -lt $pairs.Count; $b += $BatchSize){
                $nBatch++
                $lines = New-Object System.Collections.Generic.List[string]
                $lines.Add("# sap-cc-analyze batch $nBatch (<= $BatchSize objects) -- feed to /sap-atc --object-list")
                $end = [Math]::Min($b + $BatchSize, $pairs.Count) - 1
                for ($k = $b; $k -le $end; $k++){ $lines.Add("$($pairs[$k][0]) $($pairs[$k][1])") }
                $bPath = Join-Path $batchDir ('analyze_batch_{0:000}.tsv' -f $nBatch)
                Write-Utf8NoBom $bPath (($lines -join "`r`n") + "`r`n")
            }
            Write-Output "BATCHES: total=$nBatch size=$BatchSize dir=$batchDir"
        }

        if ($count -eq 0) { Write-Output 'STATUS: EMPTY'; exit 1 }
        Write-Output 'STATUS: OK'; exit 0
    }

    # ---- ingest ----
    if ([string]::IsNullOrWhiteSpace($ResultsPath)) { Write-Output 'ERROR: ingest requires -ResultsPath <file|dir>'; Write-Output 'STATUS: ERROR'; exit 2 }
    if (-not (Test-Path -LiteralPath $ResultsPath)) { Write-Output "ERROR: results path not found: $ResultsPath"; Write-Output 'STATUS: ERROR'; exit 2 }

    $resultFiles = @()
    if ((Get-Item -LiteralPath $ResultsPath).PSIsContainer) {
        $resultFiles = @(Get-ChildItem -LiteralPath $ResultsPath -File | Where-Object { $_.Extension -in @('.tsv','.txt','.csv') } | ForEach-Object { $_.FullName })
    } else { $resultFiles = @($ResultsPath) }
    if ($resultFiles.Count -eq 0) { Write-Output "ERROR: no .tsv/.txt/.csv result files under $ResultsPath"; Write-Output 'STATUS: ERROR'; exit 2 }

    # Parse + normalize all result rows to the canonical schema.
    $normRows = @()
    $objsWithFindings = @{}   # objects with at least one real finding row (upper-cased name)
    $coveredObjs = @{}        # every object the ingested evidence mentions (upper-cased name)
    # Backfill obj_type from the campaign ledger when the ATC export omits it
    # (the /sap-atc Stage-4b drill TSV has OBJECT but no type column). Without
    # this, findings carry a blank obj_type and triage's per-object (name|type)
    # rollup cannot match the state ledger, so object tiers never get stamped.
    $typeByName = @{}
    foreach ($sr in (Read-StateRows $statePath)) { if ($sr.obj_name -and $sr.obj_type) { $typeByName[$sr.obj_name.ToUpper()] = $sr.obj_type } }
    foreach ($rf in $resultFiles){
        $t = Read-Tsv $rf
        if ($t.headers.Count -eq 0 -or $t.rows.Count -eq 0) { continue }
        # map each header to a canonical column
        $map = @{}   # canonical -> column index
        for ($c = 0; $c -lt $t.headers.Count; $c++){
            $nh = Norm $t.headers[$c]
            foreach ($cn in $CANON){ if ($cn.a -contains $nh) { if (-not $map.ContainsKey($cn.n)) { $map[$cn.n] = $c } ; break } }
        }
        if (-not $map.ContainsKey('obj_name')) { Write-Output "WARN: skipping $rf -- no recognizable object-name column (headers: $($t.headers -join ','))"; continue }
        foreach ($row in $t.rows){
            $rec = [ordered]@{}
            foreach ($col in $CANON_ORDER){ $rec[$col] = if ($map.ContainsKey($col)) { (Field $row $map[$col]).Trim() } else { '' } }
            if (-not $rec['obj_name']) { continue }
            if (-not $rec['obj_type'] -and $typeByName.ContainsKey($rec['obj_name'].ToUpper())) { $rec['obj_type'] = $typeByName[$rec['obj_name'].ToUpper()] }
            $coveredObjs[$rec['obj_name'].ToUpper()] = $true
            # A row with no finding content is a checked-object marker (e.g. a
            # clean object listed in a checked-objects export): it is coverage
            # evidence only -- never fabricate an empty finding from it.
            if (-not ($rec['check_id'] -or $rec['priority'] -or $rec['message_id'] -or $rec['message_text'])) { continue }
            $normRows += [pscustomobject]$rec
            $objsWithFindings[$rec['obj_name'].ToUpper()] = $true
        }
    }

    # Append to findings_raw.tsv (dedupe on obj_name|check_id|line|message_id).
    $rawPath = Join-Path $findingsDir 'findings_raw.tsv'
    $rawHeader = ($CANON_ORDER -join "`t")
    $existing = @{}
    $existingLines = @()
    if (Test-Path -LiteralPath $rawPath){
        $all = @(Get-Content -LiteralPath $rawPath)
        if ($all.Count -ge 2){
            $existingLines = @($all[1..($all.Count - 1)] | Where-Object { $_.Trim() })
            foreach ($ln in $existingLines){ $f = $ln.Split("`t"); $existing["$((Field $f 0))|$((Field $f 2))|$((Field $f 4))|$((Field $f 5))"] = $true }
        }
    }
    $newLines = @()
    foreach ($r in $normRows){
        $key = "$($r.obj_name)|$($r.check_id)|$($r.line)|$($r.message_id)"
        if ($existing.ContainsKey($key)) { continue }
        $existing[$key] = $true
        $newLines += (@($r.obj_name,$r.obj_type,$r.check_id,$r.priority,$r.line,$r.message_id,$r.message_text,$r.simplification_item,$r.sap_note) -join "`t")
    }
    $rawOut = @($rawHeader) + $existingLines + $newLines
    Write-Utf8NoBom $rawPath (($rawOut -join "`r`n") + "`r`n")

    # Advance state SCOPED -> ANALYZED -- but ONLY for objects the ingested
    # evidence actually covers (a finding row, or a checked-object marker row).
    # The prepared worklist alone is NOT evidence a run happened: a partially
    # run ATC loop must leave unrun objects SCOPED instead of recording them
    # analyzed-clean. Clean objects advance via a checked-objects export row
    # (see SKILL.md Step 2 "Record clean objects as checked").
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $stateRows = @(Read-StateRows $statePath)
    $analyzedCount = 0
    foreach ($r in $stateRows){
        if ($r.state -eq 'SCOPED' -and $coveredObjs.ContainsKey("$($r.obj_name)".ToUpper())){
            $r.state = 'ANALYZED'; $r.updated_on = $today; $analyzedCount++
        }
    }
    Write-StateRows $statePath $stateRows

    # Worklist coverage summary: worklist objects with no evidence in this
    # ingest stayed in their prior state -- surface how many.
    $wlTotal = 0; $wlUncovered = 0
    $wlPath = Join-Path $findingsDir 'analyze_worklist.tsv'
    if (Test-Path -LiteralPath $wlPath){
        $wl = @(Get-Content -LiteralPath $wlPath)
        for ($i = 1; $i -lt $wl.Count; $i++){
            if (-not $wl[$i].Trim()) { continue }
            $f = $wl[$i].Split("`t"); $wlTotal++
            if (-not $coveredObjs.ContainsKey((Field $f 0).Trim().ToUpper())) { $wlUncovered++ }
        }
    }

    # Summary.
    $allRaw = @()
    if (Test-Path -LiteralPath $rawPath){ $a = @(Get-Content -LiteralPath $rawPath); if ($a.Count -ge 2){ $allRaw = @($a[1..($a.Count-1)] | Where-Object { $_.Trim() }) } }
    $byPrio = @{}
    foreach ($ln in $allRaw){ $p = (Field ($ln.Split("`t")) 3).Trim(); if (-not $p) { $p = '-' }; if ($byPrio.ContainsKey($p)) { $byPrio[$p]++ } else { $byPrio[$p] = 1 } }
    $objCount = $objsWithFindings.Keys.Count
    Write-Output "FINDINGS: total=$($allRaw.Count) new=$($newLines.Count) objects_with_findings=$objCount file=$rawPath"
    foreach ($p in ($byPrio.Keys | Sort-Object)){ Write-Output "PRIORITY: $p | COUNT: $($byPrio[$p])" }
    Write-Output "ANALYZED: $analyzedCount"
    Write-Output "INFO: $wlUncovered of $wlTotal worklist objects not covered by this ingest"
    Write-Output 'STATUS: OK'; exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output 'STATUS: ERROR'; exit 2
}
