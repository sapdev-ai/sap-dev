# sap-cc-triage helper -- classify ATC findings against the knowledge pack (OFFLINE)
#
# Joins findings\findings_raw.tsv to shared\knowledge\catalog.tsv per the pack's
# documented contract (README "How it is consumed"):
#   match precedence: message_id  >  simplification_item  >  code_regex
#   on tie at a level: prefer status=ACTIVE, then catalog order
#   no match -> pattern=UNMATCHED, fixability=REVIEW (leave for human triage)
# Writes findings\findings_triaged.tsv (per-finding) and advances state.tsv
# ANALYZED -> TRIAGED, stamping each object's rolled-up tier:
#   no findings           -> '-'   (clean; nothing to remediate)
#   any UNMATCHED finding  -> '?'   (needs human triage; never auto-remediated)
#   all findings matched   -> max severity (R4>R3>R2>R1)
#
# Params:
#   -CampaignDir <dir>     (required)
#   -KnowledgeDir <dir>    knowledge pack folder (default: ..\..\shared\knowledge;
#                          pass {custom_url}\knowledge to use a customer override)
#
# Output grammar (parseable):
#   TRIAGE: findings=<n> matched=<n> unmatched=<n> objects=<n> file=<path>
#   PATTERN: <pattern_id> | COUNT: <n>
#   TIER: <R1|R2|R3|R4> | COUNT: <n>
#   STATUS: OK | EMPTY | ERROR
# Exit: 0 ok | 1 empty (no findings) | 2 error

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CampaignDir,
    [string]$KnowledgeDir = ''
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 Get-Content defaults to ANSI; force UTF-8 so findings
# with non-ASCII (e.g. localized) message text classify + echo correctly.
$PSDefaultParameterValues['Get-Content:Encoding'] = 'UTF8'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Utf8NoBom([string]$Path,[string]$Text){
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Text,$enc)
}
function Field($arr,[int]$i){ if ($i -ge 0 -and $i -lt $arr.Length) { return [string]$arr[$i] } else { return '' } }
function Cell($f,$idx,[string]$name){ if ($idx.ContainsKey($name)) { return (Field $f $idx[$name]).Trim() } else { return '' } }

# csv field -> hashtable of UPPER-cased tokens (for case-insensitive membership)
function CsvSet([string]$s){
    $h = @{}
    if ($s) { foreach ($t in $s.Split(',')) { $tt = $t.Trim().ToUpper(); if ($tt) { $h[$tt] = $true } } }
    return $h
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

function Read-Catalog([string]$dir){
    $p = Join-Path $dir 'catalog.tsv'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $all = @(Get-Content -LiteralPath $p)
    if ($all.Count -lt 2) { return @() }
    $hdr = @($all[0].Split("`t") | ForEach-Object { $_.Trim() })
    $idx = @{}; for ($i = 0; $i -lt $hdr.Count; $i++){ $idx[$hdr[$i]] = $i }
    $rows = @()
    for ($i = 1; $i -lt $all.Count; $i++){
        $ln = $all[$i]; if (-not $ln.Trim()) { continue }
        $f = $ln.Split("`t")
        $rows += [pscustomobject]@{
            pattern_id         = (Cell $f $idx 'pattern_id')
            category           = (Cell $f $idx 'category')
            tier               = (Cell $f $idx 'tier')
            detect_simpl_items = (Cell $f $idx 'detect_simpl_items')
            detect_message_ids = (Cell $f $idx 'detect_message_ids')
            detect_code_regex  = (Cell $f $idx 'detect_code_regex')
            recipe_ref         = (Cell $f $idx 'recipe_ref')
            confidence_default = (Cell $f $idx 'confidence_default')
            status             = (Cell $f $idx 'status')
            _msgset            = (CsvSet (Cell $f $idx 'detect_message_ids'))
            _simplset          = (CsvSet (Cell $f $idx 'detect_simpl_items'))
        }
    }
    return $rows
}

$SEV = @{ 'R1' = 1; 'R2' = 2; 'R3' = 3; 'R4' = 4 }
function Sev-Name([int]$n){ switch ($n) { 1 { 'R1' } 2 { 'R2' } 3 { 'R3' } 4 { 'R4' } default { '-' } } }
function Est-Effort([string]$tier){ switch ($tier) { 'R1' { 'S' } 'R2' { 'M' } 'R3' { 'M' } 'R4' { 'L' } default { '-' } } }

# Pick the best candidate: prefer ACTIVE, then first (catalog order).
function Pick-Best($cands){
    if ($cands.Count -eq 0) { return $null }
    $active = @($cands | Where-Object { $_.status -eq 'ACTIVE' })
    if ($active.Count -ge 1) { return $active[0] }
    return $cands[0]
}

try {
    if (-not (Test-Path -LiteralPath (Join-Path $CampaignDir 'campaign.json'))) { Write-Output "ERROR: campaign workspace not found at $CampaignDir"; Write-Output 'STATUS: ERROR'; exit 2 }
    $rawPath = Join-Path $CampaignDir 'findings\findings_raw.tsv'
    if (-not (Test-Path -LiteralPath $rawPath)) { Write-Output 'ERROR: findings_raw.tsv missing -- run /sap-cc-analyze first'; Write-Output 'STATUS: EMPTY'; exit 1 }

    if ([string]::IsNullOrWhiteSpace($KnowledgeDir)) {
        $KnowledgeDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'shared\knowledge'
    }
    $catalog = Read-Catalog $KnowledgeDir
    if ($null -eq $catalog) { Write-Output "ERROR: knowledge catalog not found at $KnowledgeDir\catalog.tsv"; Write-Output 'STATUS: ERROR'; exit 2 }

    # Load findings_raw. A header-only file means analyze ran and found nothing
    # (a clean campaign) -- that is NOT an error: fall through so every ANALYZED
    # object is advanced to TRIAGED with a clean tier ('-').
    $all = @(Get-Content -LiteralPath $rawPath)
    if ($all.Count -lt 1) { Write-Output 'ERROR: findings_raw.tsv unreadable/empty -- run /sap-cc-analyze'; Write-Output 'STATUS: ERROR'; exit 2 }
    $isClean = ($all.Count -lt 2)
    $rhdr = @($all[0].Split("`t") | ForEach-Object { $_.Trim() })
    $ri = @{}; for ($i = 0; $i -lt $rhdr.Count; $i++){ $ri[$rhdr[$i]] = $i }

    $outHeader = "obj_name`tobj_type`tcheck_id`tpriority`tline`tmessage_id`tmessage_text`tsimplification_item`tsap_note`tpattern`ttier`tcategory`tfixability`test_effort`trecipe_ref`tmatch_basis`tstatus"
    $outLines = New-Object System.Collections.Generic.List[string]
    $outLines.Add($outHeader)

    $perObj = @{}   # "name|type" -> @{ has=$true; unmatched=$bool; maxsev=int }
    $patCount = @{}; $tierCount = @{}
    $nFind = 0; $nMatched = 0; $nUnmatched = 0

    for ($i = 1; $i -lt $all.Count; $i++){
        $ln = $all[$i]; if (-not $ln.Trim()) { continue }
        $f = $ln.Split("`t")
        $objn = (Cell $f $ri 'obj_name'); if (-not $objn) { continue }
        $objt = (Cell $f $ri 'obj_type')
        $chk  = (Cell $f $ri 'check_id')
        $prio = (Cell $f $ri 'priority')
        $line = (Cell $f $ri 'line')
        $mid  = (Cell $f $ri 'message_id')
        $mtx  = (Cell $f $ri 'message_text')
        $si   = (Cell $f $ri 'simplification_item')
        $note = (Cell $f $ri 'sap_note')
        $nFind++

        # --- classify (msgid > simpl > regex) ---
        $chosen = $null; $basis = 'NONE'
        if ($mid) {
            $u = $mid.ToUpper()
            $c = @($catalog | Where-Object { $_._msgset.ContainsKey($u) })
            if ($c.Count -ge 1) { $chosen = Pick-Best $c; $basis = 'MESSAGE_ID' }
        }
        if (-not $chosen -and $si) {
            $u = $si.ToUpper()
            $c = @($catalog | Where-Object { $_._simplset.ContainsKey($u) })
            if ($c.Count -ge 1) { $chosen = Pick-Best $c; $basis = 'SIMPL_ITEM' }
        }
        if (-not $chosen) {
            $hay = "$mtx`n$chk"
            $c = @($catalog | Where-Object {
                if (-not $_.detect_code_regex) { return $false }
                try { return [regex]::IsMatch($hay, $_.detect_code_regex) } catch { return $false }
            })
            if ($c.Count -ge 1) { $chosen = Pick-Best $c; $basis = 'CODE_REGEX' }
        }

        $key = "$objn|$objt"
        if (-not $perObj.ContainsKey($key)) { $perObj[$key] = @{ has = $true; unmatched = $false; maxsev = 0 } }
        $perObj[$key].has = $true

        if ($chosen) {
            $nMatched++
            $pat = $chosen.pattern_id; $tier = $chosen.tier; $cat = $chosen.category
            $fix = $chosen.confidence_default; $rec = $chosen.recipe_ref; $st = $chosen.status
            $eff = Est-Effort $tier
            if ($patCount.ContainsKey($pat)) { $patCount[$pat]++ } else { $patCount[$pat] = 1 }
            if ($tier) { if ($tierCount.ContainsKey($tier)) { $tierCount[$tier]++ } else { $tierCount[$tier] = 1 } }
            $s = if ($SEV.ContainsKey($tier)) { $SEV[$tier] } else { 0 }
            if ($s -gt $perObj[$key].maxsev) { $perObj[$key].maxsev = $s }
        } else {
            $nUnmatched++
            $pat = 'UNMATCHED'; $tier = '-'; $cat = ''; $fix = 'REVIEW'; $rec = ''; $st = ''; $eff = '-'
            $perObj[$key].unmatched = $true
        }
        $outLines.Add((@($objn,$objt,$chk,$prio,$line,$mid,$mtx,$si,$note,$pat,$tier,$cat,$fix,$eff,$rec,$basis,$st) -join "`t"))
    }

    $triagedPath = Join-Path $CampaignDir 'findings\findings_triaged.tsv'
    Write-Utf8NoBom $triagedPath (($outLines -join "`r`n") + "`r`n")

    # --- advance state ANALYZED -> TRIAGED, stamp rolled-up object tier ---
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $statePath = Join-Path $CampaignDir 'state.tsv'
    $stateRows = @(Read-StateRows $statePath)
    $nObjTriaged = 0
    foreach ($r in $stateRows){
        if ($r.state -ne 'ANALYZED') { continue }
        $key = "$($r.obj_name)|$($r.obj_type)"
        $objTier = '-'
        if ($perObj.ContainsKey($key)) {
            if ($perObj[$key].unmatched) { $objTier = '?' }      # has unclassified findings -> manual
            elseif ($perObj[$key].maxsev -gt 0) { $objTier = (Sev-Name $perObj[$key].maxsev) }
            else { $objTier = '?' }
        }
        # else: ANALYZED with zero findings -> clean -> '-'
        $r.state = 'TRIAGED'; $r.tier = $objTier; $r.updated_on = $today
        $nObjTriaged++
    }
    Write-StateRows $statePath $stateRows

    # --- summary ---
    Write-Output "TRIAGE: findings=$nFind matched=$nMatched unmatched=$nUnmatched objects=$nObjTriaged file=$triagedPath"
    if ($isClean) { Write-Output 'CLEAN: analyze produced 0 findings -- all ANALYZED objects triaged clean (tier -)' }
    foreach ($p in ($patCount.Keys | Sort-Object)) { Write-Output "PATTERN: $p | COUNT: $($patCount[$p])" }
    foreach ($t in @('R1','R2','R3','R4')) { if ($tierCount.ContainsKey($t)) { Write-Output "TIER: $t | COUNT: $($tierCount[$t])" } }
    Write-Output 'STATUS: OK'
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output 'STATUS: ERROR'
    exit 2
}
