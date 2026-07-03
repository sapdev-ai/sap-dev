# sap-cc-decommission helper -- plan + record the physical retirement of unused
# custom objects (OFFLINE; all SAP writes are delegated by the SKILL.md).
#
# /sap-cc-usage FLAGS unused objects (decision=DECOMMISSION / state=DECOMMISSIONED)
# but nothing is ever deleted -- so "40-60% of custom code is unused" stays a
# spreadsheet, not a realized saving. This skill EXECUTES the retirement behind a
# signed gate and a per-object safety chain, and records an auditable ledger.
#
# Two file-only actions (no SAP/RFC/GUI here -- re-verify, source backup, TR,
# delete and delete-verify are delegated to /sap-cc-usage's where-used gate,
# sap_object_resolver.ps1, sap_rfc_read_source.ps1 + sap_artifact_lib.ps1,
# /sap-transport-request, and /sap-se38|24|11 + /sap-function-group by the SKILL):
#
#   plan   : behind the decommission_signoff gate, select the retirement
#            candidates (scope.tsv decision=DECOMMISSION, plus any operator-
#            promoted -Objects that are REVIEW in scope.tsv), minus anything
#            already in decommissioned.tsv (idempotent). Order consumers before
#            providers (DDIC last). Write decommission_worklist.tsv with a
#            per-object delete-routing hint. Nothing is deleted; state unchanged.
#   record : given a results file (obj_name,obj_type,outcome[,backup_artifact_id,
#            tr]) with outcome RETIRED|FAILED|SKIPPED, append RETIRED rows to
#            decommissioned.tsv (the audit ledger) with a verified-gone timestamp
#            and the signoff owner, and stamp state.tsv. FAILED/SKIPPED are
#            counted, never ledgered.
#
# SAFETY: the gate is HARD (BLOCKED exit 3 until decommission_signoff is APPROVED)
# -- deletions propagate to QA/PROD via the TR, so a physical retirement can never
# be run without a recorded sign-off. The engine never talks to SAP: it plans and
# records; the SKILL.md runs the delegated, verified delete chain on the source
# system. A candidate is retired in the ledger ONLY after the SKILL confirms
# (resolver re-read = NOT_FOUND) it is physically gone.
#
# Params:
#   -Action <plan|record>   (required)
#   -CampaignDir <dir>      (required)
#   -Objects <csv>          (plan) operator-promoted REVIEW objects to also retire
#   -IncludeReview          (plan) include ALL scope.tsv REVIEW rows as candidates
#                           (use only after the where-used gate cleared them)
#   -ResultsFile <path>     (record) outcomes TSV
#   -Force                  (plan) emit the worklist even if the gate is unset in
#                           campaign.json (still blocks on an explicit PENDING/REJECTED)
#
# Output grammar (parseable):
#   CANDIDATE: <name> | TYPE: <t> | VIA: <route> | SRC: <DECISION|PROMOTED>
#   PLAN: candidates=<n> decommission=<d> promoted=<p> already_retired=<r> unmapped=<u>
#   RECORD: retired=<n> failed=<f> skipped=<s>
#   BLOCKED: gate=decommission_signoff status=<PENDING|REJECTED|UNSET> action=plan  (exit 3)
#   STATUS: OK | EMPTY | ERROR | BLOCKED
# Exit: 0 ok | 1 empty (nothing to retire) | 2 error | 3 blocked (sign-off not APPROVED)

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('plan','record')][string]$Action,
    [Parameter(Mandatory)][string]$CampaignDir,
    [string]$Objects = '',
    [switch]$IncludeReview,
    [string]$ResultsFile = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Get-Content:Encoding'] = 'UTF8'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Utf8NoBom([string]$Path,[string]$Text){
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Text,$enc)
}
function Field($arr,[int]$i){ if ($i -ge 0 -and $i -lt $arr.Length) { return [string]$arr[$i] } else { return '' } }

# Delete-routing by TADIR object type -> the delegated workbench skill.
function Route-For([string]$ty){
    switch ("$ty".ToUpper()) {
        'PROG' { 'se38' } 'REPS' { 'se38' }
        'CLAS' { 'se24' } 'INTF' { 'se24' }
        'FUGR' { 'function-group' }
        'TABL' { 'se11' } 'VIEW' { 'se11' } 'DTEL' { 'se11' } 'DOMA' { 'se11' }
        'TTYP' { 'se11' } 'SHLP' { 'se11' } 'ENQU' { 'se11' } 'STRU' { 'se11' }
        default { 'MANUAL' }
    }
}
# Delete order rank: consumers first, providers (DDIC, depended-upon) last.
function Order-Rank([string]$ty){
    switch ("$ty".ToUpper()) {
        'PROG' { 0 } 'REPS' { 0 } 'CLAS' { 1 } 'INTF' { 1 } 'FUGR' { 2 }
        'SHLP' { 5 } 'VIEW' { 6 } 'TABL' { 7 } 'TTYP' { 7 } 'STRU' { 7 }
        'ENQU' { 7 } 'DTEL' { 8 } 'DOMA' { 9 }
        default { 3 }
    }
}

function Read-Tsv([string]$path){
    $o = @{ headers=@(); rows=@(); idx=@{} }
    if (-not (Test-Path -LiteralPath $path)) { return $o }
    $all = @(Get-Content -LiteralPath $path)
    if ($all.Count -eq 0) { return $o }
    $o.headers = @($all[0].Split("`t") | ForEach-Object { $_.Trim() })
    for ($i=0;$i -lt $o.headers.Count;$i++){ $o.idx[$o.headers[$i]] = $i }
    for ($i=1;$i -lt $all.Count;$i++){ if ($all[$i].Trim()) { $o.rows += ,@($all[$i].Split("`t")) } }
    return $o
}
function Cell($row,$idx,[string]$name){ if ($idx.ContainsKey($name)) { return (Field $row $idx[$name]).Trim() } else { return '' } }

$LEDGER_HEADER = "obj_name`tobj_type`tbackup_artifact_id`ttr`tverified_gone_ts`tsignoff_owner`tnotes"
function Read-Ledger([string]$path){
    $h = @{}
    $t = Read-Tsv $path
    foreach ($r in $t.rows) { $k = ((Field $r 0) + '|' + (Field $r 1)).ToUpper(); if ($k -ne '|') { $h[$k] = $r } }
    return $h
}

if (-not (Test-Path -LiteralPath (Join-Path $CampaignDir 'campaign.json'))) { Write-Output "ERROR: campaign workspace not found at $CampaignDir"; Write-Output 'STATUS: ERROR'; exit 2 }
$statePath  = Join-Path $CampaignDir 'state.tsv'
$scopePath  = Join-Path $CampaignDir 'scope.tsv'
$ledgerPath = Join-Path $CampaignDir 'decommission\decommissioned.tsv'
$worklistPath = Join-Path $CampaignDir 'decommission\decommission_worklist.tsv'
$decDir = Join-Path $CampaignDir 'decommission'
if (-not (Test-Path -LiteralPath $decDir)) { New-Item -ItemType Directory -Force -Path $decDir | Out-Null }
$today = (Get-Date).ToString('yyyy-MM-dd')

$cj = $null
try { $cj = Get-Content -LiteralPath (Join-Path $CampaignDir 'campaign.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cj = $null }

try {
    if ($Action -eq 'plan') {
        # --- HARD GATE: decommission_signoff must be APPROVED --------------------
        # Deletions propagate to QA/PROD via the TR, so this is the enforceable
        # point. Default: the gate is ON. -Force lets a gate that is simply UNSET
        # in campaign.json proceed (for a fresh workspace), but an explicit PENDING
        # or REJECTED always blocks.
        $gateSet = $false; $gateOn = $true
        if ($cj -and $cj.human_gates -and $null -ne $cj.human_gates.decommission_signoff) { $gateSet = $true; $gateOn = [bool]$cj.human_gates.decommission_signoff }
        $so = $null
        if ($cj -and $cj.signoffs) { foreach ($s in @($cj.signoffs)) { if (([string]$s.gate) -eq 'decommission_signoff') { $so = $s } } }
        $gstat = if ($so -and $so.status) { [string]$so.status } else { 'UNSET' }
        if ($gateOn -and $gstat -ne 'APPROVED') {
            if ($gstat -eq 'UNSET' -and $Force) {
                # allowed through with -Force (fresh workspace, gate never recorded)
            } else {
                Write-Output "BLOCKED: gate=decommission_signoff status=$gstat action=plan"
                Write-Output 'INFO: retirement deletes are transported to QA/PROD. Record the sign-off first: /sap-cc-campaign signoff --campaign <id> --gate decommission_signoff --owner <name>'
                Write-Output 'STATUS: BLOCKED'
                exit 3
            }
        }

        $scope = Read-Tsv $scopePath
        if ($scope.rows.Count -eq 0) { Write-Output 'PLAN: candidates=0 decommission=0 promoted=0 already_retired=0 unmapped=0'; Write-Output 'STATUS: EMPTY'; exit 1 }
        $ledger = Read-Ledger $ledgerPath
        $promote = @{}
        foreach ($nm in @($Objects.Split(',') | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })) { $promote[$nm] = $true }

        $cands = @()
        foreach ($r in $scope.rows) {
            $nm = (Cell $r $scope.idx 'obj_name'); $ty = (Cell $r $scope.idx 'obj_type'); $dec = (Cell $r $scope.idx 'decision').ToUpper()
            if (-not $nm) { continue }
            $key = "$nm|$ty".ToUpper()
            $src = ''
            if ($dec -eq 'DECOMMISSION') { $src = 'DECISION' }
            elseif ($promote.ContainsKey($nm.ToUpper()) -and $dec -eq 'REVIEW') { $src = 'PROMOTED' }
            elseif ($IncludeReview -and $dec -eq 'REVIEW') { $src = 'PROMOTED' }
            if (-not $src) { continue }
            if ($ledger.ContainsKey($key)) { continue }   # already physically retired
            $cands += [pscustomobject]@{ obj_name=$nm; obj_type=$ty; src=$src; via=(Route-For $ty); rank=(Order-Rank $ty) }
        }
        $alreadyRetired = $ledger.Count
        if ($cands.Count -eq 0) { Write-Output "PLAN: candidates=0 decommission=0 promoted=0 already_retired=$alreadyRetired unmapped=0"; Write-Output 'STATUS: EMPTY'; exit 1 }

        $ordered = @($cands | Sort-Object rank, obj_type, obj_name)
        $L = New-Object System.Collections.Generic.List[string]
        $L.Add("obj_name`tobj_type`tsrc`tdelete_via`torder_rank")
        $nDec=0; $nProm=0; $nUnmapped=0
        foreach ($c in $ordered) {
            $L.Add("$($c.obj_name)`t$($c.obj_type)`t$($c.src)`t$($c.via)`t$($c.rank)")
            Write-Output "CANDIDATE: $($c.obj_name) | TYPE: $($c.obj_type) | VIA: $($c.via) | SRC: $($c.src)"
            if ($c.src -eq 'DECISION') { $nDec++ } else { $nProm++ }
            if ($c.via -eq 'MANUAL') { $nUnmapped++ }
        }
        Write-Utf8NoBom $worklistPath (($L -join "`r`n") + "`r`n")
        Write-Output "PLAN: candidates=$($ordered.Count) decommission=$nDec promoted=$nProm already_retired=$alreadyRetired unmapped=$nUnmapped"
        Write-Output 'STATUS: OK'
        Write-Output 'NOTE: PLAN only -- for each worklist row the SKILL re-verifies (where-used + resolver), backs up source, resolves a TR, deletes via the routed skill, confirms NOT_FOUND, then -Action record. Unmapped (MANUAL) types need operator handling.'
        exit 0
    }

    # ---- record ----
    if ([string]::IsNullOrWhiteSpace($ResultsFile) -or -not (Test-Path -LiteralPath $ResultsFile)) { Write-Output "ERROR: -ResultsFile not found: $ResultsFile"; Write-Output 'STATUS: ERROR'; exit 2 }
    $res = Read-Tsv $ResultsFile
    if ($res.rows.Count -eq 0) { Write-Output 'ERROR: results file has no rows'; Write-Output 'STATUS: EMPTY'; exit 1 }

    $signoffOwner = ''
    if ($cj -and $cj.signoffs) { foreach ($s in @($cj.signoffs)) { if (([string]$s.gate) -eq 'decommission_signoff' -and ([string]$s.status) -eq 'APPROVED') { $signoffOwner = [string]$s.owner } } }

    # state.tsv (advance retired objects to DECOMMISSIONED; ledger is proof of physical delete)
    $stateRows = @(); $stIdx = @{}
    if (Test-Path -LiteralPath $statePath) {
        $st = Read-Tsv $statePath
        for ($i=0;$i -lt $st.rows.Count;$i++){
            $r = $st.rows[$i]
            $stateRows += [pscustomobject]@{ obj_name=(Field $r 0); obj_type=(Field $r 1); state=(Field $r 2); tier=(Field $r 3); decision=(Field $r 4); updated_on=(Field $r 5) }
        }
        for ($i=0;$i -lt $stateRows.Count;$i++){ $stIdx["$($stateRows[$i].obj_name)|$($stateRows[$i].obj_type)".ToUpper()] = $i }
    }

    $ledger = Read-Ledger $ledgerPath
    $nR=0; $nF=0; $nS=0
    foreach ($r in $res.rows) {
        $nm = (Cell $r $res.idx 'obj_name'); $ty = (Cell $r $res.idx 'obj_type'); $out = (Cell $r $res.idx 'outcome').ToUpper()
        if (-not $nm) { continue }
        $key = "$nm|$ty".ToUpper()
        switch ($out) {
            'RETIRED' {
                $nR++
                $bk = (Cell $r $res.idx 'backup_artifact_id'); $tr = (Cell $r $res.idx 'tr')
                $ledger[$key] = @($nm,$ty,$bk,$tr,$today,$signoffOwner,'')
                if ($stIdx.ContainsKey($key)) { $stateRows[$stIdx[$key]].state = 'DECOMMISSIONED'; $stateRows[$stIdx[$key]].decision = 'DECOMMISSION'; $stateRows[$stIdx[$key]].updated_on = $today }
            }
            'FAILED'  { $nF++ }
            default   { $nS++ }
        }
    }

    # write ledger
    $LL = New-Object System.Collections.Generic.List[string]
    $LL.Add($LEDGER_HEADER)
    foreach ($k in ($ledger.Keys | Sort-Object)) { $row = $ledger[$k]; $LL.Add(($row -join "`t")) }
    Write-Utf8NoBom $ledgerPath (($LL -join "`r`n") + "`r`n")

    if ($stateRows.Count -gt 0) {
        $SL = New-Object System.Collections.Generic.List[string]
        $SL.Add("obj_name`tobj_type`tstate`ttier`tdecision`tupdated_on")
        foreach ($sr in $stateRows) { $SL.Add("$($sr.obj_name)`t$($sr.obj_type)`t$($sr.state)`t$($sr.tier)`t$($sr.decision)`t$($sr.updated_on)") }
        Write-Utf8NoBom $statePath (($SL -join "`r`n") + "`r`n")
    }

    Write-Output "RECORD: retired=$nR failed=$nF skipped=$nS"
    Write-Output 'STATUS: OK'
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output 'STATUS: ERROR'
    exit 2
}
