# sap-cc-remediate helper -- R1 mechanical remediation (dry-run) + state record (OFFLINE)
#
# Two file-only actions (no SAP/RFC/GUI here -- deploy/activate/ATC-recheck are
# delegated to /sap-se38|37|24, /sap-activate-object, /sap-atc by the SKILL.md):
#
#   apply  : for each TRIAGED R1 object, read its downloaded source
#            (remediation\<obj>.before.abap), apply migration_rules_r1.tsv, and
#            write <obj>.after.abap + <obj>.diff + a fixlog row. AUTO rules
#            rewrite; FLAG rules only report (no change). DRY-RUN -- never
#            advances state, never touches SAP. Human reviews the diffs (gate).
#   record : given a deploy/recheck results file (obj_name,obj_type,outcome with
#            outcome VERIFIED|DEPLOYED|FAILED), advance the ledger and stamp the
#            fixlog. Offline. Allowed transitions:
#              TRIAGED    -> REMEDIATED  (outcome DEPLOYED)
#              TRIAGED    -> VERIFIED    (outcome VERIFIED; deploy + recheck in one pass)
#              REMEDIATED -> VERIFIED    (outcome VERIFIED; recheck after an earlier DEPLOYED record)
#              REMEDIATED -> TRIAGED     (outcome FAILED; recheck failed -- back into the loop)
#            Any other jump is blocked (illegal transition; state unchanged).
#
# SAFETY: only objects whose state is TRIAGED and tier is exactly R1 are touched.
# Objects with tier '?' (unclassified findings), R2/R3/R4, or DRAFT-pattern
# findings are NOT auto-remediated here -- they are AI/human work.
#
# Params:
#   -Action <apply|record>  (required)
#   -CampaignDir <dir>      (required)
#   -RulesFile <path>       R1 rule pack (default: this references\migration_rules_r1.tsv;
#                           customer override e.g. {custom_url}\knowledge\migration_rules_r1.tsv)
#   -SourceDir <dir>        where <obj>.before.abap live (default: {CampaignDir}\remediation)
#   -Limit <int>            (apply) cap objects processed (0 = all)
#   -ResultsFile <path>     (record) outcomes TSV
#
# Output grammar (parseable):
#   APPLY: objects=<n> changed=<n> flagged=<n> norule=<n> missing=<n>
#   OBJ: <name> | STATUS: <s> | AUTO: <n> | FLAG: <n>
#   RECORD: verified=<n> remediated=<n> failed=<n>
#   STATUS: OK | EMPTY | ERROR
# Exit: 0 ok | 1 empty (nothing to do) | 2 error

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('apply','record','assist')][string]$Action,
    [Parameter(Mandatory)][string]$CampaignDir,
    [string]$RulesFile = '',
    [string]$SourceDir = '',
    [int]$Limit = 0,
    [string]$ResultsFile = '',
    [string]$KnowledgeDir = ''
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 Get-Content defaults to ANSI; force UTF-8 so recipe .md,
# the knowledge maps, and (critically) ABAP source with non-ASCII comments
# (e.g. Japanese) read + round-trip correctly instead of mojibaking.
$PSDefaultParameterValues['Get-Content:Encoding'] = 'UTF8'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Utf8NoBom([string]$Path,[string]$Text){
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Text,$enc)
}
function Field($arr,[int]$i){ if ($i -ge 0 -and $i -lt $arr.Length) { return [string]$arr[$i] } else { return '' } }
function Cell($f,$idx,[string]$name){ if ($idx.ContainsKey($name)) { return (Field $f $idx[$name]).Trim() } else { return '' } }

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

$FIXLOG_HEADER = "obj_name`tobj_type`tstatus`tauto_changes`tflag_hits`tdeploy_status`tatc_recheck`tupdated_on`tnotes"
function Read-Fixlog([string]$path){
    $h = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $h }
    $all = @(Get-Content -LiteralPath $path)
    for ($i = 1; $i -lt $all.Count; $i++){
        $ln = $all[$i]; if (-not $ln.Trim()) { continue }
        $f = $ln.Split("`t")
        $key = "$((Field $f 0))|$((Field $f 1))"
        $h[$key] = [pscustomobject]@{
            obj_name=(Field $f 0); obj_type=(Field $f 1); status=(Field $f 2); auto_changes=(Field $f 3)
            flag_hits=(Field $f 4); deploy_status=$(if((Field $f 5)){(Field $f 5)}else{'-'}); atc_recheck=$(if((Field $f 6)){(Field $f 6)}else{'-'})
            updated_on=(Field $f 7); notes=(Field $f 8)
        }
    }
    return $h
}
function Write-Fixlog([string]$path,$map){
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add($FIXLOG_HEADER)
    foreach ($k in ($map.Keys | Sort-Object)) {
        $r = $map[$k]
        $L.Add("$($r.obj_name)`t$($r.obj_type)`t$($r.status)`t$($r.auto_changes)`t$($r.flag_hits)`t$($r.deploy_status)`t$($r.atc_recheck)`t$($r.updated_on)`t$($r.notes)")
    }
    Write-Utf8NoBom $path (($L -join "`r`n") + "`r`n")
}

function Read-Rules([string]$path){
    $rules = @()
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $all = @(Get-Content -LiteralPath $path)
    if ($all.Count -lt 2) { return @() }
    $hdr = @($all[0].Split("`t") | ForEach-Object { $_.Trim() })
    $ix = @{}; for ($i = 0; $i -lt $hdr.Count; $i++){ $ix[$hdr[$i]] = $i }
    for ($i = 1; $i -lt $all.Count; $i++){
        $ln = $all[$i]; if (-not $ln.Trim()) { continue }
        $f = $ln.Split("`t")
        $rules += [pscustomobject]@{
            rule_id = (Cell $f $ix 'rule_id'); mode = (Cell $f $ix 'mode').ToUpper()
            ic = ((Cell $f $ix 'ignore_case').ToUpper() -eq 'Y')
            regex = (Cell $f $ix 'match_regex'); replace = (Cell $f $ix 'replace')
        }
    }
    return $rules
}

# Generic tab reader (used by the assist context-assembly for the knowledge maps).
function Read-KTsv([string]$path){
    $o = @{ headers = @(); rows = @() }
    if (-not (Test-Path -LiteralPath $path)) { return $o }
    $all = @(Get-Content -LiteralPath $path)
    if ($all.Count -eq 0) { return $o }
    $o.headers = @($all[0].Split("`t") | ForEach-Object { $_.Trim() })
    for ($i = 1; $i -lt $all.Count; $i++){ if ($all[$i].Trim()) { $o.rows += ,@($all[$i].Split("`t")) } }
    return $o
}
# Markdown table of a knowledge map's rows for one pattern_id (or '_none_').
function Md-MapTable([string]$path,[string]$patternId,[string[]]$cols){
    $t = Read-KTsv $path
    if ($t.headers.Count -eq 0) { return ,@('_none_') }
    $ix = @{}; for ($i = 0; $i -lt $t.headers.Count; $i++){ $ix[$t.headers[$i]] = $i }
    if (-not $ix.ContainsKey('pattern_id')) { return ,@('_none_') }
    $hits = @($t.rows | Where-Object { (Field $_ $ix['pattern_id']).Trim() -eq $patternId })
    if ($hits.Count -eq 0) { return ,@('_none_') }
    $L = @()
    $L += ('| ' + ($cols -join ' | ') + ' |')
    $L += ('|' + (($cols | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($r in $hits){
        $cells = @()
        foreach ($c in $cols){ $cells += $(if ($ix.ContainsKey($c)) { (Field $r $ix[$c]).Trim() } else { '' }) }
        $L += ('| ' + ($cells -join ' | ') + ' |')
    }
    return ,$L
}

if (-not (Test-Path -LiteralPath (Join-Path $CampaignDir 'campaign.json'))) { Write-Output "ERROR: campaign workspace not found at $CampaignDir"; Write-Output 'STATUS: ERROR'; exit 2 }
$remDir = if ($SourceDir) { $SourceDir } else { Join-Path $CampaignDir 'remediation' }
if (-not (Test-Path -LiteralPath $remDir)) { New-Item -ItemType Directory -Force -Path $remDir | Out-Null }
$statePath  = Join-Path $CampaignDir 'state.tsv'
$fixlogPath = Join-Path $CampaignDir 'remediation\fixlog.tsv'
$today = (Get-Date).ToString('yyyy-MM-dd')

try {
    if ($Action -eq 'apply') {
        if ([string]::IsNullOrWhiteSpace($RulesFile)) { $RulesFile = Join-Path $PSScriptRoot 'migration_rules_r1.tsv' }
        $rules = Read-Rules $RulesFile
        if ($null -eq $rules) { Write-Output "ERROR: R1 rule pack not found at $RulesFile"; Write-Output 'STATUS: ERROR'; exit 2 }
        $autoRules = @($rules | Where-Object { $_.mode -eq 'AUTO' })
        $flagRules = @($rules | Where-Object { $_.mode -eq 'FLAG' })

        $r1 = @(Read-StateRows $statePath | Where-Object { $_.state -eq 'TRIAGED' -and $_.tier -eq 'R1' })
        if ($r1.Count -eq 0) { Write-Output 'APPLY: objects=0 changed=0 flagged=0 norule=0 missing=0'; Write-Output 'STATUS: EMPTY'; exit 1 }

        $fix = Read-Fixlog $fixlogPath
        $nChanged = 0; $nFlagged = 0; $nNoRule = 0; $nMissing = 0; $nDone = 0
        foreach ($o in $r1) {
            if ($Limit -gt 0 -and $nDone -ge $Limit) { break }
            $nDone++
            $key = "$($o.obj_name)|$($o.obj_type)"
            $src = Join-Path $remDir "$($o.obj_name).before.abap"
            if (-not (Test-Path -LiteralPath $src)) { $src = Join-Path $remDir "$($o.obj_name).abap" }
            if (-not (Test-Path -LiteralPath $src)) {
                $nMissing++
                $fix[$key] = [pscustomobject]@{ obj_name=$o.obj_name; obj_type=$o.obj_type; status='SOURCE_MISSING'; auto_changes=0; flag_hits=0; deploy_status='-'; atc_recheck='-'; updated_on=$today; notes="download source to $remDir\$($o.obj_name).before.abap" }
                Write-Output "OBJ: $($o.obj_name) | STATUS: SOURCE_MISSING | AUTO: 0 | FLAG: 0"
                continue
            }
            $lines = @(Get-Content -LiteralPath $src)
            $after = New-Object System.Collections.Generic.List[string]
            $diff = New-Object System.Collections.Generic.List[string]
            $auto = 0; $flag = 0
            for ($n = 0; $n -lt $lines.Count; $n++){
                $orig = $lines[$n]; $cur = $orig
                foreach ($ru in $autoRules) {
                    $opt = if ($ru.ic) { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase } else { [System.Text.RegularExpressions.RegexOptions]::None }
                    try { $new = [regex]::Replace($cur, $ru.regex, $ru.replace, $opt) } catch { $new = $cur }
                    if ($new -ne $cur) { $cur = $new }
                }
                if ($cur -ne $orig) {
                    $auto++
                    $diff.Add("@@ L$($n+1)"); $diff.Add("- $orig"); $diff.Add("+ $cur")
                }
                foreach ($ru in $flagRules) {
                    $opt = if ($ru.ic) { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase } else { [System.Text.RegularExpressions.RegexOptions]::None }
                    try { $hit = [regex]::IsMatch($cur, $ru.regex, $opt) } catch { $hit = $false }
                    if ($hit) { $flag++; $diff.Add("! L$($n+1) FLAG $($ru.rule_id): $cur") }
                }
                $after.Add($cur)
            }
            Write-Utf8NoBom (Join-Path $remDir "$($o.obj_name).after.abap") (($after -join "`r`n") + "`r`n")
            if ($diff.Count -gt 0) { Write-Utf8NoBom (Join-Path $remDir "$($o.obj_name).diff") (($diff -join "`r`n") + "`r`n") }
            $status = if ($auto -gt 0) { 'DRYRUN_CHANGED' } elseif ($flag -gt 0) { 'FLAGGED' } else { 'NO_RULE_HIT' }
            if ($auto -gt 0) { $nChanged++ } elseif ($flag -gt 0) { $nFlagged++ } else { $nNoRule++ }
            $note = if ($flag -gt 0) { "$flag FLAG hit(s) need manual review" } else { '' }
            $fix[$key] = [pscustomobject]@{ obj_name=$o.obj_name; obj_type=$o.obj_type; status=$status; auto_changes=$auto; flag_hits=$flag; deploy_status='-'; atc_recheck='-'; updated_on=$today; notes=$note }
            Write-Output "OBJ: $($o.obj_name) | STATUS: $status | AUTO: $auto | FLAG: $flag"
        }
        Write-Fixlog $fixlogPath $fix
        Write-Output "APPLY: objects=$nDone changed=$nChanged flagged=$nFlagged norule=$nNoRule missing=$nMissing"
        Write-Output 'STATUS: OK'
        Write-Output 'NOTE: DRY-RUN only -- review remediation\*.diff, then deploy approved <obj>.after.abap via /sap-se38|37|24 + /sap-activate-object + /sap-atc, then run -Action record.'
        exit 0
    }

    # ---- assist (R2/R3 AI context assembly; no rewrite, no SAP) ----
    if ($Action -eq 'assist') {
        if ([string]::IsNullOrWhiteSpace($KnowledgeDir)) {
            $KnowledgeDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'shared\knowledge'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $KnowledgeDir 'catalog.tsv'))) { Write-Output "ERROR: knowledge pack not found at $KnowledgeDir"; Write-Output 'STATUS: ERROR'; exit 2 }
        $triagedPath = Join-Path $CampaignDir 'findings\findings_triaged.tsv'
        if (-not (Test-Path -LiteralPath $triagedPath)) { Write-Output 'ERROR: findings_triaged.tsv missing -- run /sap-cc-triage first'; Write-Output 'STATUS: EMPTY'; exit 1 }
        $r23 = @(Read-StateRows $statePath | Where-Object { $_.state -eq 'TRIAGED' -and ($_.tier -eq 'R2' -or $_.tier -eq 'R3') })
        if ($r23.Count -eq 0) { Write-Output 'ASSIST: objects=0 ready=0 draft=0 missing=0'; Write-Output 'STATUS: EMPTY'; exit 1 }

        $tAll = @(Get-Content -LiteralPath $triagedPath)
        $thdr = @($tAll[0].Split("`t") | ForEach-Object { $_.Trim() }); $ti = @{}; for ($i = 0; $i -lt $thdr.Count; $i++){ $ti[$thdr[$i]] = $i }
        $byObj = @{}
        for ($i = 1; $i -lt $tAll.Count; $i++){
            $ln = $tAll[$i]; if (-not $ln.Trim()) { continue }
            $f = $ln.Split("`t"); $on = (Cell $f $ti 'obj_name'); $ot = (Cell $f $ti 'obj_type'); if (-not $on) { continue }
            $k = "$on|$ot"; if (-not $byObj.ContainsKey($k)) { $byObj[$k] = @() }
            $byObj[$k] += [pscustomobject]@{ line=(Cell $f $ti 'line'); pattern=(Cell $f $ti 'pattern'); tier=(Cell $f $ti 'tier'); fixability=(Cell $f $ti 'fixability'); message=(Cell $f $ti 'message_text'); simpl=(Cell $f $ti 'simplification_item'); status=(Cell $f $ti 'status') }
        }

        $fix = Read-Fixlog $fixlogPath
        $nReady = 0; $nDraft = 0; $nMissing = 0; $nDone = 0
        foreach ($o in $r23){
            if ($Limit -gt 0 -and $nDone -ge $Limit) { break }
            $nDone++
            $key = "$($o.obj_name)|$($o.obj_type)"
            $finds = if ($byObj.ContainsKey($key)) { @($byObj[$key]) } else { @() }
            $pats = @($finds | Where-Object { $_.pattern -and $_.pattern -ne 'UNMATCHED' } | ForEach-Object { $_.pattern } | Select-Object -Unique)
            $anyDraft = (@($finds | Where-Object { $_.status -eq 'DRAFT' }).Count -gt 0)
            $src = Join-Path $remDir "$($o.obj_name).before.abap"
            if (-not (Test-Path -LiteralPath $src)) { $src = Join-Path $remDir "$($o.obj_name).abap" }
            $missing = -not (Test-Path -LiteralPath $src)

            $L = New-Object System.Collections.Generic.List[string]
            $L.Add("# Remediation context: $($o.obj_name) ($($o.obj_type)) -- tier $($o.tier)")
            $L.Add("")
            $L.Add("Patterns: " + ($pats -join ', '))
            if ($anyDraft) { $L.Add(""); $L.Add("> WARNING: a DRAFT pattern is involved. DRAFT mappings are ADVISORY ONLY -- verify object/field/API names against the target release; do NOT deploy a DRAFT-based rewrite without human + functional sign-off.") }
            $L.Add(""); $L.Add("## Findings")
            $L.Add("| line | pattern | tier | fixability | message | simplification_item |")
            $L.Add("|---|---|---|---|---|---|")
            foreach ($fd in $finds){ $L.Add("| $($fd.line) | $($fd.pattern) | $($fd.tier) | $($fd.fixability) | $($fd.message) | $($fd.simpl) |") }
            foreach ($p in $pats){
                $L.Add(""); $L.Add("## Pattern: $p")
                $rf = Join-Path $KnowledgeDir "recipes\$p.md"
                $L.Add("### Recipe ($p)"); $L.Add("")
                if (Test-Path -LiteralPath $rf) { $L.Add((Get-Content -LiteralPath $rf -Raw).TrimEnd()) } else { $L.Add("_recipe file not found: recipes\$p.md_") }
                $L.Add(""); $L.Add("### Object map")
                foreach ($x in (Md-MapTable (Join-Path $KnowledgeDir 'object_map.tsv') $p @('old_object','new_object','access_mode','relationship','caveat'))) { $L.Add($x) }
                $L.Add(""); $L.Add("### Field map")
                foreach ($x in (Md-MapTable (Join-Path $KnowledgeDir 'field_map.tsv') $p @('old_field','new_source','new_kind','derivation','notes'))) { $L.Add($x) }
                $L.Add(""); $L.Add("### API replacements")
                foreach ($x in (Md-MapTable (Join-Path $KnowledgeDir 'api_replacements.tsv') $p @('old_api','new_api','released','notes'))) { $L.Add($x) }
            }
            $L.Add(""); $L.Add("## Source")
            if ($missing) { $L.Add("_SOURCE MISSING: download to $remDir\$($o.obj_name).before.abap via /sap-se38|37|24 before rewriting._") }
            else { $L.Add('```abap'); $L.Add(((Get-Content -LiteralPath $src -Raw)).TrimEnd()); $L.Add('```') }
            $L.Add(""); $L.Add("## Your task (AI, recipe-guided)")
            $L.Add("1. Rewrite the source so every ACTIVE pattern finding clears, following that pattern's recipe + the maps above.")
            $L.Add("2. READ redirects (base table -> NSDM_V_* / compatibility view) are safe to propose. WRITE paths to stock/FI base tables are NOT -- escalate to MANUAL (do not rewrite).")
            $L.Add("3. ADD_ORDER_BY: add ORDER BY/SORT only where order is actually relied upon (BINARY SEARCH / first-row logic), keeping the key consistent with the BINARY SEARCH key; otherwise make no change and say so.")
            $L.Add("4. Write the rewrite to remediation\$($o.obj_name).after.abap and a short rationale to remediation\$($o.obj_name).rationale.md.")
            $L.Add("5. MANDATORY human review of the diff before any deploy. DRAFT patterns: verify mappings on the target release first.")
            Write-Utf8NoBom (Join-Path $remDir "$($o.obj_name).context.md") (($L -join "`r`n") + "`r`n")

            $st = if ($missing) { 'SOURCE_MISSING' } elseif ($anyDraft) { 'AI_CONTEXT_DRAFT' } else { 'AI_CONTEXT_READY' }
            if ($missing) { $nMissing++ } elseif ($anyDraft) { $nDraft++ } else { $nReady++ }
            $note = "$($finds.Count) finding(s)"; if ($anyDraft) { $note += '; involves DRAFT pattern - verify mappings' }
            $fix[$key] = [pscustomobject]@{ obj_name=$o.obj_name; obj_type=$o.obj_type; status=$st; auto_changes=0; flag_hits=0; deploy_status='-'; atc_recheck='-'; updated_on=$today; notes=$note }
            Write-Output "OBJ: $($o.obj_name) | TIER: $($o.tier) | PATTERNS: $($pats -join ',') | CONTEXT: $st"
        }
        Write-Fixlog $fixlogPath $fix
        Write-Output "ASSIST: objects=$nDone ready=$nReady draft=$nDraft missing=$nMissing"
        Write-Output 'STATUS: OK'
        Write-Output 'NOTE: context bundles at remediation\<obj>.context.md. AI writes <obj>.after.abap (human-reviewed) then deploy + -Action record (same loop as R1).'
        exit 0
    }

    # ---- record ----
    if ([string]::IsNullOrWhiteSpace($ResultsFile) -or -not (Test-Path -LiteralPath $ResultsFile)) { Write-Output "ERROR: -ResultsFile not found: $ResultsFile"; Write-Output 'STATUS: ERROR'; exit 2 }
    $all = @(Get-Content -LiteralPath $ResultsFile)
    if ($all.Count -lt 2) { Write-Output 'ERROR: results file has no rows'; Write-Output 'STATUS: EMPTY'; exit 1 }
    $hdr = @($all[0].Split("`t") | ForEach-Object { $_.Trim() }); $ix = @{}; for ($i=0;$i -lt $hdr.Count;$i++){ $ix[$hdr[$i]]=$i }

    $stateRows = @(Read-StateRows $statePath)
    $stIdx = @{}; for ($i=0;$i -lt $stateRows.Count;$i++){ $stIdx["$($stateRows[$i].obj_name)|$($stateRows[$i].obj_type)"] = $i }
    $fix = Read-Fixlog $fixlogPath
    $nV = 0; $nR = 0; $nF = 0
    for ($i = 1; $i -lt $all.Count; $i++){
        $ln = $all[$i]; if (-not $ln.Trim()) { continue }
        $f = $ln.Split("`t")
        $nm = (Cell $f $ix 'obj_name'); $ty = (Cell $f $ix 'obj_type'); $out = (Cell $f $ix 'outcome').ToUpper()
        if (-not $nm) { continue }
        $key = "$nm|$ty"
        if ($stIdx.ContainsKey($key)) {
            $r = $stateRows[$stIdx[$key]]
            # Ledger transition table (see header). VERIFIED is reachable from
            # TRIAGED (deploy + recheck recorded in one pass) AND from
            # REMEDIATED (recheck recorded after an earlier DEPLOYED record --
            # without this, a deployed object could never reach VERIFIED and
            # the campaign wedged at "await ATC re-check"). A FAILED recheck on
            # a REMEDIATED object returns it to TRIAGED so the remediation loop
            # picks it up again. Everything else (e.g. SCOPED -> VERIFIED) is
            # an illegal jump and is blocked.
            if ($out -eq 'VERIFIED' -and $r.state -in @('TRIAGED','REMEDIATED')) { $r.state = 'VERIFIED'; $r.updated_on = $today }
            elseif ($out -eq 'DEPLOYED' -and $r.state -eq 'TRIAGED') { $r.state = 'REMEDIATED'; $r.updated_on = $today }
            elseif ($out -eq 'FAILED' -and $r.state -eq 'REMEDIATED') { $r.state = 'TRIAGED'; $r.updated_on = $today }
        }
        if ($fix.ContainsKey($key)) {
            $fr = $fix[$key]
            if ($out -eq 'VERIFIED') { $fr.deploy_status='OK'; $fr.atc_recheck='CLEAN'; $fr.status='VERIFIED' }
            elseif ($out -eq 'DEPLOYED') { $fr.deploy_status='OK'; $fr.atc_recheck='PENDING'; $fr.status='DEPLOYED' }
            else { $fr.deploy_status='FAILED'; $fr.status='FAILED' }
            $fr.updated_on = $today
        }
        switch ($out) { 'VERIFIED' { $nV++ } 'DEPLOYED' { $nR++ } default { $nF++ } }
    }
    Write-StateRows $statePath $stateRows
    Write-Fixlog $fixlogPath $fix
    Write-Output "RECORD: verified=$nV remediated=$nR failed=$nF"
    Write-Output 'STATUS: OK'
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output 'STATUS: ERROR'
    exit 2
}
