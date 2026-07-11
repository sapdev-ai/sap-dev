# =============================================================================
# sap_cutover_ledger.ps1  -  local, crash-safe cutover ledger for /sap-cutover-runbook
#
# LOCAL ONLY (no RFC, no SAP). Three actions:
#   parse   raw grid TSV (Claude dumps the workbook per the /sap-docs-extract precedent) +
#           column-map -> runbook_draft.tsv + gaps.md. Step-type is a PROPOSAL, MANUAL by
#           default, never guessed upward. Curation is a hard gate downstream.
#   commit  validate the curated draft (unique ids, deps resolve, no cycle, >=1 checkpoint) ->
#           immutable cutover.json + empty events.jsonl. Refuses on any validation failure.
#   state   replay cutover.json + events.jsonl -> state.tsv (derived; torn last line quarantined,
#           reopen supersedes done). Never rewrites history.
#
#   -Action parse   -Grid <raw.tsv> -ColumnMap <map.tsv> -OutDir <ledgerdir>
#   -Action commit  -Draft <draft.tsv> -CutoverId <id> -OutDir <ledgerdir>
#   -Action state   -OutDir <ledgerdir> [-Json]
#
# stdout: CUTOVER_LEDGER: ... + STATUS: OK|CUTOVER_PARSE_FAILED|CUTOVER_DEP_CYCLE|... ; exit 0/1/2
# =============================================================================
[CmdletBinding()]
param(
    [ValidateSet('parse','commit','state','record')]
    [string] $Action = 'state',
    [string] $Grid       = '',
    [string] $ColumnMap  = '',
    [string] $Draft      = '',
    [string] $CutoverId  = '',
    [string] $OutDir     = '',
    [string] $StepId     = '',
    [string] $Event      = '',
    [string] $Actor      = '',
    [string] $Note       = '',
    [string] $EvidenceRef= '',
    [string] $Verify     = '',
    [string] $RunId      = '',
    [switch] $Json
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$STEP_TYPES = @('MANUAL','TRANSPORT_IMPORT','JOB_SCHEDULE','REPORT_RUN','TABLE_CHECK')

function Norm { param([string]$s) return (("$s") -replace '[^A-Za-z0-9]','').ToLower() }
function Utc  { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Read-Tsv { param([string]$path)
    # emits one [pscustomobject] per data row directly to the pipeline; callers use @(Read-Tsv ..)
    if (-not (Test-Path $path)) { return }
    $lines = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8).TrimStart([char]0xFEFF) -split "`r`n|`n"
    $hdr = $null
    foreach ($ln in $lines) {
        if ($null -eq $ln) { continue }
        if ($ln.TrimStart().StartsWith('#')) { continue }
        if ($ln.Trim() -eq '') { continue }
        $c = @($ln -split "`t")
        if ($null -eq $hdr) { $hdr = $c; continue }
        $o = [ordered]@{}
        for ($i = 0; $i -lt $hdr.Count; $i++) {
            $k = "$($hdr[$i])".Trim()
            if ($k -eq '') { $k = "col$i" }
            if ($i -lt $c.Count) { $o[$k] = "$($c[$i])".Trim() } else { $o[$k] = '' }
        }
        [pscustomobject]$o
    }
}

# ---- column-map: canonical -> synonym set (normalized) ----
function Load-ColumnMap { param([string]$path)
    $map=@{}
    if (-not (Test-Path $path)) { return $map }
    foreach ($ln in ([IO.File]::ReadAllText($path,[Text.Encoding]::UTF8).TrimStart([char]0xFEFF) -split "`r`n|`n")) {
        if (-not $ln -or $ln.TrimStart().StartsWith('#')) { continue }
        $c = $ln -split "`t"; if ($c.Count -lt 1) { continue }
        $canon=$c[0].Trim(); if (-not $canon -or $canon -eq 'canonical') { continue }
        $syns=@(); for ($i=1;$i -lt $c.Count;$i++){ if ($c[$i].Trim()) { $syns += (Norm $c[$i]) } }
        if (-not ($syns -contains (Norm $canon))) { $syns += (Norm $canon) }
        $map[$canon]=$syns
    }
    return $map
}

function Classify-StepType { param([string]$text,[string]$declared)
    if ($declared -and ($STEP_TYPES -contains $declared.ToUpper())) { return $declared.ToUpper() }
    $t = " $text "
    # TR key = 3-char SID (letter then 2 alphanumerics, e.g. S4D / ID3 / DEV) + K + 6 alphanumerics
    if ($text -match '\b[A-Z][A-Z0-9]{2}K[0-9A-Z]{6}\b') { return 'TRANSPORT_IMPORT' }
    if ($t -match '(?i)\b(schedule|batch job|sm36|job\b|jobs\b)' ) { return 'JOB_SCHEDULE' }
    if ($t -match '(?i)\b(run report|execute report|se38|sa38|submit|program\b)') { return 'REPORT_RUN' }
    if ($t -match '(?i)\b(check table|count table|verify table|row count|se16|reconcile count)') { return 'TABLE_CHECK' }
    return 'MANUAL'   # never guessed upward
}

if (-not $OutDir) { Write-Host 'STATUS: CUTOVER_PARSE_FAILED reason=no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

# =========================== parse ==========================================
if ($Action -eq 'parse') {
    if (-not (Test-Path $Grid)) { Write-Host 'STATUS: CUTOVER_PARSE_FAILED reason=grid_not_found'; exit 2 }
    $map = Load-ColumnMap $ColumnMap
    $stepRows = @(Read-Tsv $Grid)
    if ($stepRows.Count -eq 0) { Write-Host 'STATUS: CUTOVER_PARSE_FAILED reason=zero_rows'; exit 1 }
    # resolve each canonical field to the matching grid header
    $gridHdrs = @($stepRows[0].PSObject.Properties.Name)
    $colFor=@{}
    foreach ($canon in $map.Keys) {
        foreach ($h in $gridHdrs) { if ($map[$canon] -contains (Norm $h)) { $colFor[$canon]=$h; break } }
    }
    $val = { param($row,$canon) if ($colFor.ContainsKey($canon)) { "$($row.$($colFor[$canon]))".Trim() } else { '' } }

    $draftRows=@(); $gaps=@(); $idx=0
    foreach ($row in $stepRows) {
        $idx++
        $id = & $val $row 'id'; if (-not $id) { $id = "$idx" }
        $text = & $val $row 'text'; if (-not $text) { $text = ($row.PSObject.Properties | ForEach-Object { $_.Value }) -join ' ' }
        $declared = & $val $row 'step_type'
        $stype = Classify-StepType $text $declared
        $system = & $val $row 'system'
        $owner  = & $val $row 'owner'
        $dur    = & $val $row 'planned_duration'; if ($dur -notmatch '^\d+$') { $dur='' }
        $deps   = (& $val $row 'depends_on') -replace '\s*[,;/]\s*',','
        $cp     = & $val $row 'checkpoint'
        $auto   = 'NO'
        $trk    = & $val $row 'trkorr'; if (-not $trk -and $stype -eq 'TRANSPORT_IMPORT' -and $text -match '\b([A-Z][A-Z0-9]{2}K[0-9A-Z]{6})\b') { $trk=$Matches[1] }
        $job    = & $val $row 'jobname'
        $tbl    = & $val $row 'table'
        $whr    = & $val $row 'where'
        # gaps
        if (-not $owner) { $gaps += "step ${id}: missing owner" }
        if (-not $dur)   { $gaps += "step ${id}: missing planned_duration" }
        if ($stype -eq 'TRANSPORT_IMPORT' -and -not $trk) { $gaps += "step ${id}: TRANSPORT_IMPORT without a TRKORR -> will downgrade to MANUAL at commit unless filled" }
        if ($stype -eq 'JOB_SCHEDULE' -and -not $job)     { $gaps += "step ${id}: JOB_SCHEDULE without jobname -> fill or it becomes MANUAL" }
        if ($stype -eq 'TABLE_CHECK' -and -not $tbl)      { $gaps += "step ${id}: TABLE_CHECK without table -> fill or it becomes MANUAL" }
        if ($stype -ne 'MANUAL' -and -not $system)        { $gaps += "step ${id}: automatable step without target system profile" }
        $draftRows += [pscustomobject]@{ id=$id; phase=(& $val $row 'phase'); text=$text; step_type=$stype; system=$system; owner=$owner; planned_start=(& $val $row 'planned_start'); planned_duration=$dur; depends_on=$deps; checkpoint=$cp; auto_ok=$auto; trkorr=$trk; jobname=$job; table=$tbl; where=$whr }
    }
    # write draft
    $cols = 'id','phase','text','step_type','system','owner','planned_start','planned_duration','depends_on','checkpoint','auto_ok','trkorr','jobname','table','where'
    $sb=New-Object System.Text.StringBuilder; [void]$sb.AppendLine(($cols -join "`t"))
    foreach ($r in $draftRows) { [void]$sb.AppendLine((($cols | ForEach-Object { ("$($r.$_)") -replace "`t",' ' }) -join "`t")) }
    $draftPath = Join-Path $OutDir 'runbook_draft.tsv'
    [IO.File]::WriteAllText($draftPath, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
    $gb=New-Object System.Text.StringBuilder
    [void]$gb.AppendLine("# Curation gaps for cutover draft ($($draftRows.Count) steps)")
    [void]$gb.AppendLine('')
    if ($gaps.Count) { foreach ($g in $gaps) { [void]$gb.AppendLine("- $g") } } else { [void]$gb.AppendLine('- (none detected -- still review step types + dependencies before commit)') }
    [IO.File]::WriteAllText((Join-Path $OutDir 'gaps.md'), $gb.ToString(), (New-Object Text.UTF8Encoding($false)))
    $auto = @($draftRows | Where-Object { $_.step_type -ne 'MANUAL' }).Count
    Write-Host ("CUTOVER_LEDGER: parsed steps={0} automatable={1} gaps={2} draft={3}" -f $draftRows.Count,$auto,$gaps.Count,$draftPath)
    Write-Host ("STATUS: OK action=parse steps={0}" -f $draftRows.Count)
    exit 0
}

# =========================== commit =========================================
if ($Action -eq 'commit') {
    if (-not (Test-Path $Draft)) { Write-Host 'STATUS: CUTOVER_PARSE_FAILED reason=draft_not_found'; exit 2 }
    if (-not $CutoverId) { Write-Host 'STATUS: CUTOVER_PARSE_FAILED reason=no_cutover_id'; exit 2 }
    $rows = @(Read-Tsv $Draft)
    if ($rows.Count -eq 0) { Write-Host 'STATUS: CUTOVER_PARSE_FAILED reason=zero_steps'; exit 1 }
    # unique ids
    $ids = @($rows | ForEach-Object { $_.id }); $dupe = @($ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($dupe.Count) { Write-Host ("STATUS: CUTOVER_PARSE_FAILED reason=duplicate_ids ids={0}" -f ($dupe -join ',')); exit 1 }
    $idset=@{}; foreach ($i in $ids) { $idset[$i]=$true }
    # deps resolve
    $warns=@()
    foreach ($r in $rows) {
        if ($r.depends_on) { foreach ($dp in ($r.depends_on -split ',')) { $dp=$dp.Trim(); if ($dp -and -not $idset.ContainsKey($dp)) { Write-Host ("STATUS: CUTOVER_PARSE_FAILED reason=unresolved_dep step={0} dep={1}" -f $r.id,$dp); exit 1 } } }
    }
    # cycle detection (DFS)
    $adj=@{}; foreach ($r in $rows) { $adj[$r.id]=@(); if ($r.depends_on) { $adj[$r.id]=@($r.depends_on -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } }
    $color=@{}; $cycle=$null
    function Visit { param($n) if ($cycle) { return }; $script:color[$n]='gray'; foreach ($m in $adj[$n]) { if ($script:color[$m] -eq 'gray') { $script:cycle="$m<-$n"; return } elseif (-not $script:color[$m]) { Visit $m } }; $script:color[$n]='black' }
    foreach ($r in $rows) { if (-not $color[$r.id]) { Visit $r.id } }
    if ($cycle) { Write-Host ("STATUS: CUTOVER_DEP_CYCLE edge={0}" -f $cycle); exit 1 }
    # checkpoints + verify_params downgrade
    $checkpoints = @($rows | ForEach-Object { $_.checkpoint } | Where-Object { $_ } | Select-Object -Unique)
    if ($checkpoints.Count -eq 0) { Write-Host 'STATUS: CUTOVER_PARSE_FAILED reason=no_checkpoint'; exit 1 }
    $steps=@()
    foreach ($r in $rows) {
        $st = "$($r.step_type)".ToUpper(); if (-not ($STEP_TYPES -contains $st)) { $st='MANUAL' }
        $vp = @{ trkorr="$($r.trkorr)"; target="$($r.system)"; jobname="$($r.jobname)"; table="$($r.table)"; where="$($r.where)" }
        if ($st -eq 'TRANSPORT_IMPORT' -and -not $r.trkorr) { $st='MANUAL'; $warns += "step $($r.id): TRANSPORT_IMPORT lacked TRKORR -> committed as MANUAL" }
        if ($st -eq 'JOB_SCHEDULE'     -and -not $r.jobname){ $st='MANUAL'; $warns += "step $($r.id): JOB_SCHEDULE lacked jobname -> committed as MANUAL" }
        if ($st -eq 'TABLE_CHECK'      -and -not $r.table)  { $st='MANUAL'; $warns += "step $($r.id): TABLE_CHECK lacked table -> committed as MANUAL" }
        $dur=0; if ("$($r.planned_duration)" -match '^\d+$') { $dur=[int]$r.planned_duration }
        $deps=@(); if ($r.depends_on) { $deps=@($r.depends_on -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        $auto = if ("$($r.auto_ok)".ToUpper() -eq 'YES') { 'YES' } else { 'NO' }
        $steps += [ordered]@{ id="$($r.id)"; phase="$($r.phase)"; text="$($r.text)"; step_type=$st; system="$($r.system)"; owner="$($r.owner)"; planned_start="$($r.planned_start)"; planned_duration=$dur; depends_on=$deps; checkpoint="$($r.checkpoint)"; auto_ok=$auto; verify_params=$vp }
    }
    $plan=[ordered]@{ cutover_id=$CutoverId; created_utc=(Utc); t0=$null; checkpoints=$checkpoints; steps=$steps }
    $planPath = Join-Path $OutDir 'cutover.json'
    [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $evPath = Join-Path $OutDir 'events.jsonl'
    if (-not (Test-Path $evPath)) { [IO.File]::WriteAllText($evPath, '', (New-Object Text.UTF8Encoding($false))) }
    foreach ($w in $warns) { Write-Host ("CUTOVER_LEDGER: WARN {0}" -f $w) }
    Write-Host ("CUTOVER_LEDGER: committed id={0} steps={1} checkpoints={2} plan={3}" -f $CutoverId,$steps.Count,$checkpoints.Count,$planPath)
    Write-Host ("STATUS: OK action=commit steps={0}" -f $steps.Count)
    exit 0
}

# =========================== record =========================================
if ($Action -eq 'record') {
    $planPath = Join-Path $OutDir 'cutover.json'
    if (-not (Test-Path $planPath)) { Write-Host 'STATUS: CUTOVER_LEDGER_NOT_FOUND'; exit 1 }
    $plan = Get-Content $planPath -Raw | ConvertFrom-Json
    if (-not $StepId) { Write-Host 'STATUS: CUTOVER_STEP_UNKNOWN reason=no_step_id'; exit 1 }
    $ids = @($plan.steps | ForEach-Object { "$($_.id)" })
    if (-not ($ids -contains $StepId)) { Write-Host ("STATUS: CUTOVER_STEP_UNKNOWN step={0}" -f $StepId); exit 1 }
    $legal = @('start','done','fail','skip','block','reopen')
    $ev = "$Event".ToLower()
    if (-not ($legal -contains $ev)) { Write-Host ("STATUS: CUTOVER_STEP_UNKNOWN reason=bad_event event={0}" -f $Event); exit 1 }
    $rec = [ordered]@{ ts_utc=(Utc); step_id=$StepId; event=$ev; actor=$Actor; note=$Note; evidence_ref=$EvidenceRef; verify=$Verify; run_id=$RunId }
    $line = ($rec | ConvertTo-Json -Compress -Depth 4)
    $evPath = Join-Path $OutDir 'events.jsonl'
    # single-writer append with retry (a concurrent writer or AV lock briefly holds the file)
    $ok=$false
    for ($try=0; $try -lt 5 -and -not $ok; $try++) {
        try { $sw = [IO.StreamWriter]::new($evPath, $true, (New-Object Text.UTF8Encoding($false))); $sw.WriteLine($line); $sw.Flush(); $sw.Close(); $ok=$true }
        catch { Start-Sleep -Milliseconds 150 }
    }
    if (-not $ok) { Write-Host 'STATUS: RFC_ERROR reason=events_append_failed'; exit 2 }
    Write-Host ("CUTOVER_LEDGER: recorded step={0} event={1}{2}" -f $StepId,$ev,$(if($Verify){" verify=$Verify"}else{''}))
    Write-Host ("STATUS: OK action=record step={0} event={1}" -f $StepId,$ev)
    exit 0
}

# =========================== state ==========================================
if ($Action -eq 'state') {
    $planPath = Join-Path $OutDir 'cutover.json'
    if (-not (Test-Path $planPath)) { Write-Host 'STATUS: CUTOVER_LEDGER_NOT_FOUND'; exit 1 }
    $plan = Get-Content $planPath -Raw | ConvertFrom-Json
    $evPath = Join-Path $OutDir 'events.jsonl'
    $events=@(); $quarantined=0
    if (Test-Path $evPath) {
        $lines = @([IO.File]::ReadAllLines($evPath))
        for ($i=0;$i -lt $lines.Count;$i++) {
            $ln=$lines[$i]; if (-not "$ln".Trim()) { continue }
            try { $events += ($ln | ConvertFrom-Json) } catch { $quarantined++; if ($i -ne $lines.Count-1) { Write-Host ("CUTOVER_LEDGER: WARN quarantined non-last torn line {0}" -f ($i+1)) } }
        }
    }
    # derive per-step status: latest meaningful event wins; reopen supersedes done
    $rank = @{ 'block'=1;'skip'=2;'start'=3;'fail'=4;'reopen'=5;'done'=6 }
    $st=@{}
    foreach ($s in $plan.steps) { $st["$($s.id)"]=[ordered]@{ id="$($s.id)"; phase="$($s.phase)"; step_type="$($s.step_type)"; system="$($s.system)"; status='PENDING'; actual_start=''; actual_end=''; last_ts=''; verify=''; note='' } }
    $evSorted = @($events | Sort-Object { "$($_.ts_utc)" })
    foreach ($e in $evSorted) {
        $sid="$($e.step_id)"; if (-not $st.ContainsKey($sid)) { continue }
        $ev="$($e.event)".ToLower()
        switch ($ev) {
            'start'  { $st[$sid].status='STARTED';  $st[$sid].actual_start="$($e.ts_utc)" }
            'done'   { $st[$sid].status='DONE';      $st[$sid].actual_end="$($e.ts_utc)" }
            'fail'   { $st[$sid].status='FAILED';    $st[$sid].actual_end="$($e.ts_utc)" }
            'skip'   { $st[$sid].status='SKIPPED' }
            'block'  { $st[$sid].status='BLOCKED' }
            'reopen' { $st[$sid].status='STARTED';   $st[$sid].actual_end='' }
        }
        $st[$sid].last_ts="$($e.ts_utc)"
        if ($e.note) { $st[$sid].note="$($e.note)" }
        if ($e.verify) { $st[$sid].verify="$($e.verify)" }
    }
    $cols='id','phase','step_type','system','status','actual_start','actual_end','last_ts','verify','note'
    $sb=New-Object System.Text.StringBuilder; [void]$sb.AppendLine(($cols -join "`t"))
    foreach ($s in $plan.steps) { $r=$st["$($s.id)"]; [void]$sb.AppendLine((($cols | ForEach-Object { ("$($r.$_)") -replace "`t",' ' }) -join "`t")) }
    [IO.File]::WriteAllText((Join-Path $OutDir 'state.tsv'), $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
    $done=@($st.Values | Where-Object { $_.status -eq 'DONE' }).Count
    $fail=@($st.Values | Where-Object { $_.status -eq 'FAILED' }).Count
    $blk =@($st.Values | Where-Object { $_.status -eq 'BLOCKED' }).Count
    Write-Host ("CUTOVER_LEDGER: state total={0} done={1} failed={2} blocked={3} events={4} quarantined={5}" -f $plan.steps.Count,$done,$fail,$blk,$evSorted.Count,$quarantined)
    Write-Host ("STATUS: OK action=state total={0} done={1}" -f $plan.steps.Count,$done)
    exit 0
}
