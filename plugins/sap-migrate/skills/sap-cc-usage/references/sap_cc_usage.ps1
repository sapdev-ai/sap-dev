# sap-cc-usage helper -- usage-based scoping / decommission decision (OFFLINE v1)
#
# Joins a usage export onto inventory.tsv, applies the decommission policy, and
# writes usage.tsv + scope.tsv, then advances state.tsv (decision + state).
# v1 is OFFLINE: it reads files only (no SAP/RFC). The where-used reference
# safety check that promotes conservative REVIEW -> DECOMMISSION is the next
# increment; until then conservative NEVER auto-decommissions (it parks unused
# objects as REVIEW), so the "never delete a still-referenced object" promise
# holds by construction.
#
# Params:
#   -CampaignDir <dir>   (required) the campaign workspace
#   -UsageSource <FILE|SCMON|UPL|NONE>  default: FILE if -UsageFile given else NONE
#   -UsageFile <path>    usage export (TSV/CSV: col1=object name, col2=exec count,
#                        optional col3=last used; header optional)
#   -MinExec <int>       used if exec_count > MinExec (default 0 = any hit is used)
#   -Policy <none|conservative|aggressive>  default: campaign.json scope.decommission_policy, else conservative
#   -ForceLowJoin        accept a usage file that matches < 10% of the inventory
#                        (without it such a file is rejected -- USAGE_JOIN_LOW)
#
# Output grammar (parseable):
#   USAGE_JOIN: matched=<j> inventory=<n> rate=<pct>%   (j = inventory objects the
#               usage data matched -- join hits, NOT usage-file rows)
#   USAGE: source=<src> policy=<p> min_exec=<n> matched=<j> file=<path-or-->
#   USED: <n> | UNUSED: <n> | UNKNOWN: <n>
#   DECISION: <REMEDIATE|DECOMMISSION|REVIEW> | COUNT: <n>
#   METRIC: decommission_savings_pct | VALUE: <n>
#   SCOPE: wrote <path>
#   STATUS: OK | EMPTY | ERROR
#           | ERROR USAGE_JOIN_ZERO (...)  usage file matched NO inventory object
#           | ERROR USAGE_JOIN_LOW (...)   join rate < 10% without -ForceLowJoin
#           (both join guards exit 2 WITHOUT writing usage.tsv / scope.tsv /
#            state.tsv -- a wrong-system export must never flag the estate unused)
# Exit: 0 ok | 1 empty (no inventory) | 2 error (bad workspace / inputs / join guard)

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CampaignDir,
    [string]$UsageSource = '',
    [string]$UsageFile = '',
    [int]$MinExec = 0,
    [string]$Policy = '',
    [switch]$ForceLowJoin
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 Get-Content defaults to ANSI; force UTF-8 so usage
# exports / inventory rows with non-ASCII content read correctly.
$PSDefaultParameterValues['Get-Content:Encoding'] = 'UTF8'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Utf8NoBom([string]$Path,[string]$Text){
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Text,$enc)
}
function Field($arr,[int]$i){ if ($i -lt $arr.Length) { return [string]$arr[$i] } else { return '' } }

function Read-Inventory([string]$path){
    $rows = @()
    if (-not (Test-Path -LiteralPath $path)) { return $rows }
    $all = @(Get-Content -LiteralPath $path)
    if ($all.Count -lt 2) { return $rows }
    for ($i = 1; $i -lt $all.Count; $i++){
        $ln = $all[$i]; if (-not $ln.Trim()) { continue }
        $f = $ln.Split("`t")
        $nm = (Field $f 0).Trim(); $ty = (Field $f 1).Trim()
        if ($nm) { $rows += [pscustomobject]@{ obj_name = $nm; obj_type = $ty } }
    }
    return $rows
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
            obj_name   = (Field $f 0)
            obj_type   = (Field $f 1)
            state      = (Field $f 2)
            tier       = $(if ((Field $f 3)) { (Field $f 3) } else { '-' })
            decision   = $(if ((Field $f 4)) { (Field $f 4) } else { '-' })
            updated_on = (Field $f 5)
        }
    }
    return $rows
}

function Read-UsageFile([string]$path){
    $res = @{ map = @{}; matched = 0; error = $null }
    if (-not (Test-Path -LiteralPath $path)) { $res.error = "usage file not found: $path"; return $res }
    $lines = @(Get-Content -LiteralPath $path)
    if ($lines.Count -eq 0) { $res.error = 'usage file is empty'; return $res }

    $first = $lines[0]
    $delim = if ($first.Contains("`t")) { "`t" } elseif ($first.Contains(',')) { ',' } else { $null }
    $f0 = if ($delim) { $first.Split($delim) } else { @($first) }
    $c0 = (Field $f0 0).Trim(); $c1 = (Field $f0 1).Trim()
    $t = 0; $c1IsInt = [int]::TryParse($c1, [ref]$t)
    $start = 0
    if (($c0 -match '(?i)name|object|obj|program|unit|prog') -and -not $c1IsInt) { $start = 1 }

    for ($i = $start; $i -lt $lines.Count; $i++){
        $ln = $lines[$i]; if (-not $ln.Trim()) { continue }
        $f = if ($delim) { $ln.Split($delim) } else { @($ln.Trim()) }
        $nm = (Field $f 0).Trim().ToUpper(); if (-not $nm) { continue }
        $exec = 1
        $c = (Field $f 1).Trim()
        if ($c) { $tmp = 0; if ([int]::TryParse($c, [ref]$tmp)) { $exec = $tmp } }
        $last = (Field $f 2).Trim()
        if ($res.map.ContainsKey($nm)) {
            $res.map[$nm].exec += $exec
            if ($last -and -not $res.map[$nm].last) { $res.map[$nm].last = $last }
        } else {
            $res.map[$nm] = @{ exec = $exec; last = $last }
        }
        $res.matched++
    }
    return $res
}

# --- Main --------------------------------------------------------------------
try {
    $cjson = Join-Path $CampaignDir 'campaign.json'
    if (-not (Test-Path -LiteralPath $cjson)) { Write-Output "ERROR: campaign workspace not found at $CampaignDir (run /sap-cc-campaign init)"; Write-Output 'STATUS: ERROR'; exit 2 }
    $camp = $null
    try { $camp = Get-Content -LiteralPath $cjson -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Output "ERROR: cannot parse campaign.json: $($_.Exception.Message)"; Write-Output 'STATUS: ERROR'; exit 2 }

    $invPath = Join-Path $CampaignDir 'inventory.tsv'
    $inv = @(Read-Inventory $invPath)
    if ($inv.Count -eq 0) { Write-Output 'ERROR: inventory.tsv is empty or missing -- run /sap-cc-inventory first'; Write-Output 'STATUS: EMPTY'; exit 1 }

    # Resolve policy.
    $pol = $Policy
    if ([string]::IsNullOrWhiteSpace($pol) -and $camp.scope) { $pol = "$($camp.scope.decommission_policy)" }
    if ([string]::IsNullOrWhiteSpace($pol)) { $pol = 'conservative' }
    $pol = $pol.ToLower()
    if ($pol -notin @('none','conservative','aggressive')) { Write-Output "ERROR: unknown policy '$pol' (use none|conservative|aggressive)"; Write-Output 'STATUS: ERROR'; exit 2 }

    # Resolve usage source + ingest.
    $src = $UsageSource
    if ([string]::IsNullOrWhiteSpace($src)) { $src = if ($UsageFile) { 'FILE' } else { 'NONE' } }
    $src = $src.ToUpper()
    $usageMap = @{}; $haveUsage = $false
    if ($src -eq 'FILE') {
        if ([string]::IsNullOrWhiteSpace($UsageFile)) { Write-Output 'ERROR: -UsageSource FILE requires -UsageFile'; Write-Output 'STATUS: ERROR'; exit 2 }
        $u = Read-UsageFile $UsageFile
        if ($u.error) { Write-Output "ERROR: $($u.error)"; Write-Output 'STATUS: ERROR'; exit 2 }
        $usageMap = $u.map; $haveUsage = $true
    } elseif ($src -eq 'SCMON' -or $src -eq 'UPL') {
        # Direct read: sap_cc_scmon_read.ps1 (run by the SKILL via RFC against the
        # source system) writes a usage export; we ingest it here but KEEP the
        # SCMON/UPL provenance in usage.tsv. If no export was produced (monitoring
        # not active -> reader emitted STATUS:NO_DATA), fall back to the SAFE NONE
        # path: every object -> REMEDIATE, nothing decommissioned.
        if (-not [string]::IsNullOrWhiteSpace($UsageFile) -and (Test-Path -LiteralPath $UsageFile)) {
            $u = Read-UsageFile $UsageFile
            if ($u.error) { Write-Output "ERROR: $($u.error)"; Write-Output 'STATUS: ERROR'; exit 2 }
            $usageMap = $u.map; $haveUsage = $true
        } else {
            Write-Output "WARN: no $src usage export available (run sap_cc_scmon_read.ps1 first, or pass --usage-file). Proceeding with NO usage data (all objects -> REMEDIATE; nothing decommissioned)."
            $src = 'NONE'
        }
    }
    # NONE -> no usage data: used_flag stays UNKNOWN, everything REMEDIATE (safe).

    # Join-rate guard: how many INVENTORY objects does the usage data actually
    # cover? A usage export from the wrong system (or an unparseable format)
    # matches ~none of the inventory and would otherwise flag the whole estate
    # unused (aggressive policy -> estate-wide DECOMMISSION). Zero join hits is
    # always fatal; a low rate (< 10%) needs an explicit -ForceLowJoin. Both
    # guards fire BEFORE anything is written.
    $joinHits = 0
    if ($haveUsage) {
        foreach ($o in $inv) { if ($usageMap.ContainsKey($o.obj_name.ToUpper())) { $joinHits++ } }
    }
    $joinRate = if ($inv.Count -gt 0) { 100.0 * $joinHits / $inv.Count } else { 0.0 }
    Write-Output ("USAGE_JOIN: matched=$joinHits inventory=$($inv.Count) rate=" + [math]::Round($joinRate,1) + '%')
    if ($haveUsage -and $joinHits -eq 0) {
        Write-Output 'STATUS: ERROR USAGE_JOIN_ZERO (usage file matched no inventory object - wrong system/format?)'
        exit 2
    }
    if ($haveUsage -and $joinRate -lt 10 -and -not $ForceLowJoin) {
        Write-Output ('STATUS: ERROR USAGE_JOIN_LOW (usage matched only ' + [math]::Round($joinRate,1) + '% of inventory - wrong system/format? re-run with -ForceLowJoin to accept)')
        exit 2
    }

    $today = (Get-Date).ToString('yyyy-MM-dd')

    # Build usage.tsv + per-object decision.
    $usageLines = New-Object System.Collections.Generic.List[string]
    $usageLines.Add("obj_name`tobj_type`texec_count`tlast_used_on`tusage_source`tused_flag")
    $scopeLines = New-Object System.Collections.Generic.List[string]
    $scopeLines.Add("obj_name`tobj_type`tdecision`treason`treferenced_by_used")

    $decisions = @{}   # "name|type" -> @{decision; state}
    $cntUsed = 0; $cntUnused = 0; $cntUnknown = 0
    $cntRem = 0; $cntDec = 0; $cntRev = 0

    foreach ($o in $inv) {
        $nm = $o.obj_name; $ty = $o.obj_type
        $exec = 0; $last = ''; $usedFlag = 'U'
        if ($haveUsage) {
            $key = $nm.ToUpper()
            if ($usageMap.ContainsKey($key)) { $exec = [int]$usageMap[$key].exec; $last = "$($usageMap[$key].last)" }
            $usedFlag = if ($exec -gt $MinExec) { 'Y' } else { 'N' }
        }
        switch ($usedFlag) { 'Y' { $cntUsed++ } 'N' { $cntUnused++ } default { $cntUnknown++ } }
        $usageLines.Add("$nm`t$ty`t$exec`t$last`t$src`t$usedFlag")

        # Decision per policy.
        $decision = 'REMEDIATE'; $reason = ''; $refBy = 'NOT_CHECKED'
        if ($usedFlag -eq 'U') {
            $decision = 'REMEDIATE'; $reason = 'no usage data'
        } elseif ($pol -eq 'none') {
            $decision = 'REMEDIATE'; $reason = 'policy=none'
        } elseif ($usedFlag -eq 'Y') {
            $decision = 'REMEDIATE'; $reason = "used: $exec exec(s)"; $refBy = 'N/A'
        } else {
            # unused
            if ($pol -eq 'aggressive') {
                $decision = 'DECOMMISSION'; $reason = "unused (<= $MinExec exec); aggressive policy -- no reference check"; $refBy = 'NOT_CHECKED'
            } else {
                $decision = 'REVIEW'; $reason = "unused (<= $MinExec exec); pending reference-safety check"; $refBy = 'PENDING'
            }
        }
        $scopeLines.Add("$nm`t$ty`t$decision`t$reason`t$refBy")
        switch ($decision) { 'REMEDIATE' { $cntRem++ } 'DECOMMISSION' { $cntDec++ } 'REVIEW' { $cntRev++ } }
        $stateForDecision = switch ($decision) { 'REMEDIATE' { 'SCOPED' } 'DECOMMISSION' { 'DECOMMISSIONED' } 'REVIEW' { 'REVIEW' } }
        $decisions["$nm|$ty"] = @{ decision = $decision; state = $stateForDecision }
    }

    Write-Utf8NoBom (Join-Path $CampaignDir 'usage.tsv') (($usageLines -join "`r`n") + "`r`n")
    $scopePath = Join-Path $CampaignDir 'scope.tsv'
    Write-Utf8NoBom $scopePath (($scopeLines -join "`r`n") + "`r`n")

    # Advance state.tsv: set decision + advance state from INVENTORIED; never
    # downgrade an object already past SCOPED (rank guard).
    $rank = @{ '' = 0; 'INVENTORIED' = 1; 'SCOPED' = 2; 'REVIEW' = 2; 'ANALYZED' = 3; 'TRIAGED' = 4; 'REMEDIATED' = 5; 'VERIFIED' = 6; 'TRANSPORTED' = 7; 'DECOMMISSIONED' = 7 }
    $statePath = Join-Path $CampaignDir 'state.tsv'
    $stateRows = New-Object System.Collections.Generic.List[object]
    foreach ($r in (Read-StateRows $statePath)) { $stateRows.Add($r) }
    $idx = @{}
    for ($i = 0; $i -lt $stateRows.Count; $i++){ $idx["$($stateRows[$i].obj_name)|$($stateRows[$i].obj_type)"] = $i }

    foreach ($k in $decisions.Keys) {
        $d = $decisions[$k]
        if ($idx.ContainsKey($k)) {
            $row = $stateRows[$idx[$k]]
            $row.decision = $d.decision
            $cur = "$($row.state)"; if (-not $rank.ContainsKey($cur)) { $cur = 'INVENTORIED' }
            if ($rank[$cur] -le 1) { $row.state = $d.state }   # only advance from NEW / INVENTORIED
            $row.updated_on = $today
        } else {
            $p = $k.Split('|')
            $stateRows.Add([pscustomobject]@{ obj_name = $p[0]; obj_type = (Field $p 1); state = $d.state; tier = '-'; decision = $d.decision; updated_on = $today })
        }
    }
    $stateOut = New-Object System.Collections.Generic.List[string]
    $stateOut.Add("obj_name`tobj_type`tstate`ttier`tdecision`tupdated_on")
    foreach ($r in $stateRows) { $stateOut.Add("$($r.obj_name)`t$($r.obj_type)`t$($r.state)`t$($r.tier)`t$($r.decision)`t$($r.updated_on)") }
    Write-Utf8NoBom $statePath (($stateOut -join "`r`n") + "`r`n")

    # Emit summary.
    $total = $inv.Count
    $save = if ($total -gt 0) { [int][math]::Round(100.0 * $cntDec / $total) } else { 0 }
    $fileEcho = if ($haveUsage) { $UsageFile } else { '-' }
    Write-Output "USAGE: source=$src policy=$pol min_exec=$MinExec matched=$joinHits file=$fileEcho"
    Write-Output "USED: $cntUsed | UNUSED: $cntUnused | UNKNOWN: $cntUnknown"
    Write-Output "DECISION: REMEDIATE | COUNT: $cntRem"
    Write-Output "DECISION: DECOMMISSION | COUNT: $cntDec"
    Write-Output "DECISION: REVIEW | COUNT: $cntRev"
    Write-Output "METRIC: decommission_savings_pct | VALUE: $save"
    Write-Output "SCOPE: wrote $scopePath"
    Write-Output 'STATUS: OK'
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output 'STATUS: ERROR'
    exit 2
}
