# sap-cc-remediate helper -- R1 mechanical remediation (dry-run) + state record (OFFLINE)
#
# File-only actions (no SAP/RFC/GUI here -- deploy/activate/ATC-recheck are
# delegated to /sap-se38|37|24, /sap-activate-object, /sap-atc by the SKILL.md):
#
#   apply  : for each TRIAGED R1 object, read its downloaded source
#            (remediation\<obj>.before.abap), apply migration_rules_r1.tsv, and
#            write <obj>.after.abap + <obj>.diff + a fixlog row. AUTO rules
#            rewrite; FLAG rules only report (no change). DRY-RUN -- never
#            advances state, never touches SAP. Human reviews the diffs (gate).
#   revert : stage a ROLLBACK of a deployed fix. For each selected object whose
#            fixlog row shows a deploy happened (status DEPLOYED|VERIFIED|FAILED),
#            copy the retained <obj>.before.abap to <obj>.revert.abap and write
#            <obj>.revert.diff (deployed .after.abap vs the restore target) for
#            the operator to review. Selection: -Objects "A[,B]" names explicit
#            objects (any deployed status); WITHOUT -Objects only fixlog status
#            FAILED rows are staged (the recheck-failed set -- the broken fix is
#            live on the sandbox). File-staging only: state is unchanged and
#            nothing touches SAP; the SKILL.md deploys <obj>.revert.abap via the
#            workbench skills, then records outcome REVERTED.
#   record : given a deploy/recheck results file (obj_name,obj_type,outcome with
#            outcome VERIFIED|DEPLOYED|FAILED|REVERTED), advance the ledger and
#            stamp the fixlog. Offline. Allowed transitions:
#              TRIAGED    -> REMEDIATED  (outcome DEPLOYED)
#              TRIAGED    -> VERIFIED    (outcome VERIFIED; deploy + recheck in one pass)
#              REMEDIATED -> VERIFIED    (outcome VERIFIED; recheck after an earlier DEPLOYED record)
#              REMEDIATED -> TRIAGED     (outcome FAILED; recheck failed -- back into the loop)
#              REMEDIATED -> TRIAGED     (outcome REVERTED; before-image redeployed -- back into the loop)
#              VERIFIED   -> TRIAGED     (outcome REVERTED; a verified fix rolled back)
#            (REVERTED on an already-TRIAGED object -- the recheck-failed case --
#            keeps state and stamps only the fixlog.)
#            Any other jump is blocked (illegal transition; state unchanged).
#
# SAFETY: only objects whose state is TRIAGED and tier is exactly R1 are touched.
# Objects with tier '?' (unclassified findings), R2/R3/R4, or DRAFT-pattern
# findings are NOT auto-remediated here -- they are AI/human work.
#
# Params:
#   -Action <apply|assist|revert|record>  (required)
#   -CampaignDir <dir>      (required)
#   -RulesFile <path>       R1 rule pack (default: this references\migration_rules_r1.tsv;
#                           customer override e.g. {custom_url}\knowledge\migration_rules_r1.tsv)
#   -SourceDir <dir>        where <obj>.before.abap live (default: {CampaignDir}\remediation)
#   -Limit <int>            (apply/revert) cap objects processed (0 = all)
#   -ResultsFile <path>     (record) outcomes TSV. Columns: obj_name, obj_type,
#                           outcome[, aunit_status, aunit_methods, aunit_failures].
#                           The 3 aunit_* columns are optional -- absent = units
#                           not run (treated as no-test / COULD_NOT_CHECK).
#   -Objects <csv>          (revert) explicit object names; without it only
#                           fixlog status=FAILED rows are staged
#   -GatePolicyLib <path>   (record) sap_gate_policy.ps1 -- consulted for the
#                           ABAP-Unit gate when no explicit -UnitGate override
#   -BriefPath <path>       (record) migration brief for Get-SapGatePolicy
#   -UnitGate <BLOCK|WARN|INFO>          (record) explicit unit-gate override
#   -UnitGateWhenNoTests <BLOCK|WARN>    (record) explicit no-test-class override
#
# Output grammar (parseable):
#   APPLY: objects=<n> changed=<n> flagged=<n> norule=<n> missing=<n>
#   OBJ: <name> | STATUS: <s> | AUTO: <n> | FLAG: <n>
#   REVERT: objects=<n> ready=<r> notdeployed=<s> missing=<m>
#   INFO: unit_gate=<BLOCK|WARN|INFO> unit_gate_when_no_tests=<BLOCK|WARN>   (record)
#   RECORD: verified=<n> remediated=<n> failed=<n> reverted=<n> unit_blocked=<n>
#   BLOCKED: gate=dryrun_review status=<PENDING|REJECTED> action=record   (record only; exit 3)
#   BLOCKED: gate=unit_tests obj=<name> aunit=<FAIL|NO_TESTS|NOT_RUN> failures=<n> action=record  (record; per held object; exit 3)
#   STATUS: OK | EMPTY | ERROR | BLOCKED
# Exit: 0 ok | 1 empty (nothing to do) | 2 error
#       3 blocked (dry-run review sign-off not APPROVED, OR the ABAP-Unit gate
#         held >=1 object back from VERIFIED under unit_gate=BLOCK)
#
# Gate note: `record` enforces the dryrun_review sign-off for FORWARD progress
# (VERIFIED/DEPLOYED/FAILED outcomes). A results file whose rows are ALL
# outcome=REVERTED bypasses the gate -- a rollback restores the reviewed
# before-image and reduces risk; blocking it on a sign-off would leave a broken
# fix live on the sandbox with no scripted way back.
#
# Unit-test gate (C9): when the brief's ABAP-Unit bar is mandatory (unit_gate=
# BLOCK), a VERIFIED outcome is honoured only if its results row carries
# aunit_status=PASS. A FAIL -- or (under unit_gate_when_no_tests=BLOCK) a missing
# test class -- does NOT reach VERIFIED: the object was deployed + ATC-clean, so
# it is held at REMEDIATED (deployed, not verified) and the run exits 3. Unlike
# the dryrun pre-wall (which persists nothing), the unit gate PERSISTS the
# legitimate transitions (passing VERIFIEDs, DEPLOYEDs, REVERTEDs) and holds only
# the individual objects that failed their tests -- so one red suite never blocks
# recording the rest. unit_gate=WARN records VERIFIED with a note; INFO is silent.
# An object with no test class under the default WARN policy is COULD_NOT_CHECK
# (honest), never a silent pass.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('apply','record','assist','revert')][string]$Action,
    [Parameter(Mandatory)][string]$CampaignDir,
    [string]$RulesFile = '',
    [string]$SourceDir = '',
    [int]$Limit = 0,
    [string]$ResultsFile = '',
    [string]$KnowledgeDir = '',
    [string]$Objects = '',
    # C9 -- ABAP-Unit exit gate (record only). The gate policy is brief-driven:
    # -GatePolicyLib + -BriefPath let `record` consult Get-SapGatePolicy against
    # the migration brief; -UnitGate / -UnitGateWhenNoTests are explicit overrides
    # (win over the lib) so the gate is offline-testable without the shared lib.
    [string]$GatePolicyLib = '',
    [string]$BriefPath = '',
    [ValidateSet('','BLOCK','WARN','INFO')][string]$UnitGate = '',
    [ValidateSet('','BLOCK','WARN')][string]$UnitGateWhenNoTests = ''
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

# Fixlog schema (C9 appended aunit_status/methods/failures at the END so old
# 9-column fixlogs read back with the aunit fields defaulted -- append-compatible).
$FIXLOG_HEADER = "obj_name`tobj_type`tstatus`tauto_changes`tflag_hits`tdeploy_status`tatc_recheck`tupdated_on`tnotes`taunit_status`taunit_methods`taunit_failures"
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
            aunit_status=$(if((Field $f 9)){(Field $f 9)}else{'-'}); aunit_methods=$(if((Field $f 10)){(Field $f 10)}else{'0'}); aunit_failures=$(if((Field $f 11)){(Field $f 11)}else{'0'})
        }
    }
    return $h
}
function Write-Fixlog([string]$path,$map){
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add($FIXLOG_HEADER)
    foreach ($k in ($map.Keys | Sort-Object)) {
        $r = $map[$k]
        $au  = if ($null -ne $r.aunit_status)   { $r.aunit_status }   else { '-' }
        $aum = if ($null -ne $r.aunit_methods)  { $r.aunit_methods }  else { '0' }
        $auf = if ($null -ne $r.aunit_failures) { $r.aunit_failures } else { '0' }
        $L.Add("$($r.obj_name)`t$($r.obj_type)`t$($r.status)`t$($r.auto_changes)`t$($r.flag_hits)`t$($r.deploy_status)`t$($r.atc_recheck)`t$($r.updated_on)`t$($r.notes)`t$au`t$aum`t$auf")
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

    # ---- revert (stage rollback of deployed fixes; file-staging only) ----
    # Selects fixlog rows whose fix was DEPLOYED to the sandbox (status
    # DEPLOYED|VERIFIED|FAILED -- FAILED means the ATC recheck failed AFTER a
    # deploy, i.e. the broken fix is live). Copies the retained before-image to
    # <obj>.revert.abap and writes <obj>.revert.diff (deployed .after.abap vs
    # the restore target) for operator review. NO state change, NO SAP access:
    # the SKILL.md deploys the staged file via the workbench skills (sandbox
    # assertion applies), then records outcome REVERTED.
    if ($Action -eq 'revert') {
        $fix = Read-Fixlog $fixlogPath
        $DEPLOYED_STATUSES = @('DEPLOYED','VERIFIED','FAILED')
        $wanted = @()
        if (-not [string]::IsNullOrWhiteSpace($Objects)) {
            $names = @($Objects.Split(',') | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
            foreach ($k in ($fix.Keys | Sort-Object)) { if ($names -contains ($fix[$k].obj_name.ToUpper())) { $wanted += $fix[$k] } }
            $known = @($wanted | ForEach-Object { $_.obj_name.ToUpper() })
            foreach ($nm in $names) { if ($known -notcontains $nm) { Write-Output "OBJ: $nm | STATUS: NOT_IN_FIXLOG" } }
        } else {
            # No -Objects: stage only the recheck-FAILED set (broken fix live on
            # the sandbox). Rolling back DEPLOYED/VERIFIED fixes is deliberate --
            # name them explicitly.
            foreach ($k in ($fix.Keys | Sort-Object)) { if ($fix[$k].status -eq 'FAILED') { $wanted += $fix[$k] } }
        }
        if ($wanted.Count -eq 0) { Write-Output 'REVERT: objects=0 ready=0 notdeployed=0 missing=0'; Write-Output 'STATUS: EMPTY'; exit 1 }
        $nReady = 0; $nSkip = 0; $nMiss = 0; $nDone = 0
        foreach ($r in $wanted) {
            if ($Limit -gt 0 -and $nDone -ge $Limit) { break }
            $nDone++
            if ($DEPLOYED_STATUSES -notcontains $r.status) { $nSkip++; Write-Output "OBJ: $($r.obj_name) | STATUS: NOT_DEPLOYED (fixlog status $($r.status))"; continue }
            $before = Join-Path $remDir "$($r.obj_name).before.abap"
            if (-not (Test-Path -LiteralPath $before)) { $nMiss++; Write-Output "OBJ: $($r.obj_name) | STATUS: BEFORE_MISSING (expected $before)"; continue }
            $beforeLines = @(Get-Content -LiteralPath $before)
            Write-Utf8NoBom (Join-Path $remDir "$($r.obj_name).revert.abap") (($beforeLines -join "`r`n") + "`r`n")
            $afterPath = Join-Path $remDir "$($r.obj_name).after.abap"
            if (Test-Path -LiteralPath $afterPath) {
                $afterLines = @(Get-Content -LiteralPath $afterPath)
                $diff = New-Object System.Collections.Generic.List[string]
                $max = [math]::Max($beforeLines.Count, $afterLines.Count)
                for ($n = 0; $n -lt $max; $n++) {
                    $a = if ($n -lt $afterLines.Count) { $afterLines[$n] } else { $null }
                    $b = if ($n -lt $beforeLines.Count) { $beforeLines[$n] } else { $null }
                    if ($a -cne $b) {
                        $diff.Add("@@ L$($n+1)")
                        if ($null -ne $a) { $diff.Add("- $a") }
                        if ($null -ne $b) { $diff.Add("+ $b") }
                    }
                }
                if ($diff.Count -gt 0) { Write-Utf8NoBom (Join-Path $remDir "$($r.obj_name).revert.diff") (($diff -join "`r`n") + "`r`n") }
            }
            $nReady++
            Write-Output "OBJ: $($r.obj_name) | STATUS: REVERT_READY (was $($r.status))"
        }
        Write-Output "REVERT: objects=$nDone ready=$nReady notdeployed=$nSkip missing=$nMiss"
        if ($nReady -gt 0) {
            Write-Output 'STATUS: OK'
            Write-Output 'NOTE: staging only -- review remediation\<obj>.revert.diff, deploy <obj>.revert.abap via /sap-se38|37|24 + /sap-activate-object on the SANDBOX, then -Action record with outcome REVERTED.'
            exit 0
        } else {
            Write-Output 'STATUS: EMPTY'
            exit 1
        }
    }

    # ---- record ----
    # Hard human-gate (dryrun_review): `record` is what marks campaign progress
    # (TRIAGED -> REMEDIATED/VERIFIED), so it is the enforceable point of the
    # dry-run-review gate -- the diffs are produced by -Action apply, so by the
    # time outcomes exist the review either happened (record it via
    # /sap-cc-campaign signoff) or was skipped (this wall). Honours
    # campaign.json human_gates.dryrun_review=false (gate disabled). The
    # companion `next` gate (scope_signoff) lives in sap_cc_campaign.ps1.
    # ROLLBACK EXEMPTION: a results file whose rows are ALL outcome=REVERTED
    # bypasses the gate (see header Gate note) -- the results are therefore
    # parsed BEFORE the gate check.
    if ([string]::IsNullOrWhiteSpace($ResultsFile) -or -not (Test-Path -LiteralPath $ResultsFile)) { Write-Output "ERROR: -ResultsFile not found: $ResultsFile"; Write-Output 'STATUS: ERROR'; exit 2 }
    $all = @(Get-Content -LiteralPath $ResultsFile)
    if ($all.Count -lt 2) { Write-Output 'ERROR: results file has no rows'; Write-Output 'STATUS: EMPTY'; exit 1 }
    $hdr = @($all[0].Split("`t") | ForEach-Object { $_.Trim() }); $ix = @{}; for ($i=0;$i -lt $hdr.Count;$i++){ $ix[$hdr[$i]]=$i }
    $outcomesSeen = @()
    for ($i = 1; $i -lt $all.Count; $i++){
        $ln = $all[$i]; if (-not $ln.Trim()) { continue }
        $f = $ln.Split("`t"); $o = (Cell $f $ix 'outcome').ToUpper()
        if ($o) { $outcomesSeen += $o }
    }
    $allRevert = ($outcomesSeen.Count -gt 0 -and (@($outcomesSeen | Where-Object { $_ -ne 'REVERTED' }).Count -eq 0))
    $cjPath = Join-Path $CampaignDir 'campaign.json'
    $cj = $null
    try { $cj = Get-Content -LiteralPath $cjPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cj = $null }
    $gateOn = $true
    if ($cj -and $cj.human_gates -and $null -ne $cj.human_gates.dryrun_review) { $gateOn = [bool]$cj.human_gates.dryrun_review }
    if ($gateOn -and -not $allRevert) {
        $so = $null
        if ($cj -and $cj.signoffs) { foreach ($s in @($cj.signoffs)) { if (([string]$s.gate) -eq 'dryrun_review') { $so = $s } } }
        $gstat = if ($so -and $so.status) { [string]$so.status } else { 'PENDING' }
        if ($gstat -ne 'APPROVED') {
            Write-Output "BLOCKED: gate=dryrun_review status=$gstat action=record"
            Write-Output 'INFO: review the dry-run diffs (remediation\*.diff), then record the approval: /sap-cc-campaign signoff --campaign <id> --gate dryrun_review --owner <name>'
            Write-Output 'STATUS: BLOCKED'
            exit 3
        }
    }

    # --- C9: resolve the ABAP-Unit exit gate (brief-driven; overridable) ---
    # Precedence: explicit -UnitGate/-UnitGateWhenNoTests override > Get-SapGatePolicy
    # (via -GatePolicyLib against -BriefPath) > safe default (WARN = non-blocking).
    $unitGate    = if ($UnitGate) { $UnitGate.ToUpper() } else { '' }
    $unitNoTests = if ($UnitGateWhenNoTests) { $UnitGateWhenNoTests.ToUpper() } else { '' }
    if ((-not $unitGate -or -not $unitNoTests) -and $GatePolicyLib -and (Test-Path -LiteralPath $GatePolicyLib)) {
        try {
            . $GatePolicyLib
            if (Get-Command Get-SapGatePolicy -ErrorAction SilentlyContinue) {
                $pol = Get-SapGatePolicy -BriefPath $BriefPath
                if (-not $unitGate    -and $pol.unit_gate)               { $unitGate    = "$($pol.unit_gate)".ToUpper() }
                if (-not $unitNoTests -and $pol.unit_gate_when_no_tests) { $unitNoTests = "$($pol.unit_gate_when_no_tests)".ToUpper() }
            }
        } catch { Write-Output "INFO: gate policy lib load failed ($($_.Exception.Message)); defaulting unit gate to WARN" }
    }
    if (-not $unitGate)    { $unitGate    = 'WARN' }   # no policy resolvable -> non-blocking, honest
    if (-not $unitNoTests) { $unitNoTests = 'WARN' }
    Write-Output "INFO: unit_gate=$unitGate unit_gate_when_no_tests=$unitNoTests"

    $stateRows = @(Read-StateRows $statePath)
    $stIdx = @{}; for ($i=0;$i -lt $stateRows.Count;$i++){ $stIdx["$($stateRows[$i].obj_name)|$($stateRows[$i].obj_type)"] = $i }
    $fix = Read-Fixlog $fixlogPath
    $nV = 0; $nR = 0; $nF = 0; $nRev = 0; $nUnitBlocked = 0
    for ($i = 1; $i -lt $all.Count; $i++){
        $ln = $all[$i]; if (-not $ln.Trim()) { continue }
        $f = $ln.Split("`t")
        $nm = (Cell $f $ix 'obj_name'); $ty = (Cell $f $ix 'obj_type'); $out = (Cell $f $ix 'outcome').ToUpper()
        if (-not $nm) { continue }
        $key = "$nm|$ty"

        # --- C9 unit-test gate: read the optional aunit_* columns and decide
        #     whether a VERIFIED outcome is honoured or held back at REMEDIATED. ---
        $auStatus = ''; $auMethods = '0'; $auFailures = '0'
        if ($ix.ContainsKey('aunit_status'))   { $auStatus   = (Cell $f $ix 'aunit_status').ToUpper() }
        if ($ix.ContainsKey('aunit_methods'))  { $auMethods  = (Cell $f $ix 'aunit_methods') }
        if ($ix.ContainsKey('aunit_failures')) { $auFailures = (Cell $f $ix 'aunit_failures') }
        if ([string]::IsNullOrWhiteSpace($auMethods))  { $auMethods  = '0' }
        if ([string]::IsNullOrWhiteSpace($auFailures)) { $auFailures = '0' }

        $unitHeld = $false; $unitReason = ''; $unitNote = ''
        if ($out -eq 'VERIFIED' -and $unitGate -eq 'BLOCK') {
            if ($auStatus -eq 'PASS') {
                # green units -> VERIFIED allowed
            } elseif ($auStatus -eq 'FAIL') {
                $unitHeld = $true; $unitReason = 'FAIL'
            } else {
                # no PASS on record (NO_TESTS / NOT_RUN / blank) -> no-test-class policy
                if ([string]::IsNullOrWhiteSpace($auStatus)) { $auStatus = 'NOT_RUN' }
                if ($unitNoTests -eq 'BLOCK') { $unitHeld = $true; $unitReason = $auStatus }
                else { $unitNote = "unit gate BLOCK but $auStatus (COULD_NOT_CHECK; no-test policy=WARN)" }
            }
        } elseif ($out -eq 'VERIFIED' -and $unitGate -eq 'WARN') {
            if ($auStatus -and $auStatus -ne 'PASS') { $unitNote = "unit=$auStatus (gate=WARN, not blocking)" }
        }

        if ($unitHeld) {
            # Deploy happened + ATC was clean; only unit verification is short.
            # Hold at REMEDIATED (deployed, not verified) -- never VERIFIED.
            if ($stIdx.ContainsKey($key)) {
                $r = $stateRows[$stIdx[$key]]
                if ($r.state -eq 'TRIAGED') { $r.state = 'REMEDIATED'; $r.updated_on = $today }
            }
            if ($fix.ContainsKey($key)) {
                $fr = $fix[$key]
                $fr.deploy_status='OK'; $fr.atc_recheck='CLEAN'; $fr.status='UNIT_BLOCKED'
                $fr.aunit_status=$unitReason; $fr.aunit_methods=$auMethods; $fr.aunit_failures=$auFailures
                $fr.notes="unit gate=BLOCK held ($unitReason); fix tests, re-run /sap-run-abap-unit, then re-record VERIFIED"
                $fr.updated_on = $today
            }
            Write-Output "BLOCKED: gate=unit_tests obj=$nm aunit=$unitReason failures=$auFailures action=record"
            $nUnitBlocked++
            continue
        }

        if ($stIdx.ContainsKey($key)) {
            $r = $stateRows[$stIdx[$key]]
            # Ledger transition table (see header). VERIFIED is reachable from
            # TRIAGED (deploy + recheck recorded in one pass) AND from
            # REMEDIATED (recheck recorded after an earlier DEPLOYED record --
            # without this, a deployed object could never reach VERIFIED and
            # the campaign wedged at "await ATC re-check"). A FAILED recheck on
            # a REMEDIATED object returns it to TRIAGED so the remediation loop
            # picks it up again. REVERTED returns a deployed object (REMEDIATED
            # or VERIFIED) to TRIAGED -- the before-image is live again, so the
            # object re-enters the remediation loop; on an already-TRIAGED
            # object (the recheck-FAILED case) only the fixlog is stamped.
            # Everything else (e.g. SCOPED -> VERIFIED) is an illegal jump and
            # is blocked.
            if ($out -eq 'VERIFIED' -and $r.state -in @('TRIAGED','REMEDIATED')) { $r.state = 'VERIFIED'; $r.updated_on = $today }
            elseif ($out -eq 'DEPLOYED' -and $r.state -eq 'TRIAGED') { $r.state = 'REMEDIATED'; $r.updated_on = $today }
            elseif ($out -eq 'FAILED' -and $r.state -eq 'REMEDIATED') { $r.state = 'TRIAGED'; $r.updated_on = $today }
            elseif ($out -eq 'REVERTED' -and $r.state -in @('REMEDIATED','VERIFIED')) { $r.state = 'TRIAGED'; $r.updated_on = $today }
        }
        if ($fix.ContainsKey($key)) {
            $fr = $fix[$key]
            $prevStatus = [string]$fr.status
            if ($out -eq 'VERIFIED') {
                $fr.deploy_status='OK'; $fr.atc_recheck='CLEAN'; $fr.status='VERIFIED'
                $fr.aunit_status=$(if ($auStatus) { $auStatus } else { '-' }); $fr.aunit_methods=$auMethods; $fr.aunit_failures=$auFailures
                if ($unitNote) { $fr.notes = (@($fr.notes, $unitNote) | Where-Object { $_ }) -join '; ' }
                elseif ($prevStatus -eq 'UNIT_BLOCKED') { $fr.notes = 'verified after unit-gate hold (tests green on re-record)' }
            }
            elseif ($out -eq 'DEPLOYED') { $fr.deploy_status='OK'; $fr.atc_recheck='PENDING'; $fr.status='DEPLOYED' }
            elseif ($out -eq 'REVERTED') { $fr.notes = "reverted (was $($fr.status))"; $fr.deploy_status='ROLLED_BACK'; $fr.atc_recheck='-'; $fr.status='REVERTED' }
            else { $fr.deploy_status='FAILED'; $fr.status='FAILED' }
            $fr.updated_on = $today
        }
        switch ($out) { 'VERIFIED' { $nV++ } 'DEPLOYED' { $nR++ } 'REVERTED' { $nRev++ } default { $nF++ } }
    }
    Write-StateRows $statePath $stateRows
    Write-Fixlog $fixlogPath $fix
    Write-Output "RECORD: verified=$nV remediated=$nR failed=$nF reverted=$nRev unit_blocked=$nUnitBlocked"
    if ($nUnitBlocked -gt 0) {
        Write-Output "INFO: $nUnitBlocked object(s) deployed + ATC-clean but held at REMEDIATED by the ABAP-Unit gate (unit_gate=BLOCK). Fix the failing tests, re-run /sap-run-abap-unit, then re-record with outcome VERIFIED + aunit_status=PASS."
        Write-Output 'STATUS: BLOCKED'
        exit 3
    }
    Write-Output 'STATUS: OK'
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output 'STATUS: ERROR'
    exit 2
}
