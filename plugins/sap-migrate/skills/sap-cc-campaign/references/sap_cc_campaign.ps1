# sap-cc-campaign helper -- migration campaign workspace aggregator
#
# OFFLINE: never opens a SAP session, makes no RFC call, needs no SAP NCo.
# Owns campaign.json + state.tsv writes; reads the detail files the other
# sap-cc-* skills produce. Companion to plugins/sap-migrate/skills/
# sap-cc-campaign/SKILL.md, which is the canonical workspace contract.
#
# Usage:
#   sap_cc_campaign.ps1 -Action init   -CampaignDir <dir> -CampaignId <id> [-ProfileJson '<json>']
#   sap_cc_campaign.ps1 -Action status -CampaignDir <dir>
#   sap_cc_campaign.ps1 -Action report -CampaignDir <dir>
#   sap_cc_campaign.ps1 -Action next   -CampaignDir <dir>
#
# Output grammar (STABLE -- parsed by the skill and /sap-log-analyze):
#   STATE:    <STATE> | COUNT: <n>
#   TIER:     <R1|R2|R3|R4> | COUNT: <n>
#   DECISION: <REMEDIATE|DECOMMISSION|REVIEW> | COUNT: <n>
#   PATTERN:  <pattern> | COUNT: <n>                       (report only)
#   METRIC:   <name> | VALUE: <int>          (-1 = not applicable yet)
#   NEXT:     skill=<name|MANUAL|DONE> reason=<text> [gate=<scope_signoff|dryrun_review>]
#   INIT: <text> | EXISTED: <text> | REPORT: <text>
#   STATUS:   PHASE=<phase> TOTAL=<n> REMEDIATE=<n> DECOMMISSION=<n> REVIEW=<n>
# Exit: 0 ok | 1 gap (empty ledger) | 2 error (bad/missing workspace)

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('init','status','report','next')][string]$Action,
    [Parameter(Mandatory)][string]$CampaignDir,
    [string]$CampaignId,
    [string]$ProfileJson,
    [string]$BriefPath   # reserved (the brief is parsed by Claude in the skill, not here)
)

$ErrorActionPreference = 'Stop'

# Canonical orderings (drive output line order + the dashboard tables).
$StateOrder    = @('INVENTORIED','SCOPED','ANALYZED','TRIAGED','REMEDIATED','VERIFIED','TRANSPORTED','DECOMMISSIONED','REVIEW')
$TierOrder     = @('R1','R2','R3','R4')
$DecisionOrder = @('REMEDIATE','DECOMMISSION','REVIEW')

function Write-Utf8NoBom([string]$Path,[string]$Text){
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Text,$enc)
}

# Tally one property across all rows in a single pass -- avoids the classic
# "loop variable not visible inside a Where-Object scriptblock" scoping trap.
function Tally($rows,[string]$prop){
    $h = @{}
    foreach($r in @($rows)){
        $v = [string]$r.$prop
        if($null -eq $v){ $v = '' }
        if($h.ContainsKey($v)){ $h[$v]++ } else { $h[$v] = 1 }
    }
    return $h
}
function HGet($h,[string]$k){ if($h -and $h.ContainsKey($k)){ return [int]$h[$k] } else { return 0 } }

# Count with a literal-only predicate (safe: references only $_ and constants).
function CW($rows,[scriptblock]$pred){ return @(@($rows) | Where-Object $pred).Count }

function Get-Ledger([string]$dir){
    $p = Join-Path $dir 'state.tsv'
    if(-not (Test-Path -LiteralPath $p)){ return @() }
    try { return @(Import-Csv -LiteralPath $p -Delimiter "`t") } catch { return @() }
}

# Campaign-level phase = the phase of the least-advanced REMEDIATE-track object.
function Get-Phase($rows){
    $rows = @($rows)
    if($rows.Count -eq 0){ return 'ASSESS' }
    $dH = Tally $rows 'decision'
    $undecided = (HGet $dH '') + (HGet $dH '-')
    if($undecided -gt 0){ return 'ASSESS' }
    $rem = @($rows | Where-Object { $_.decision -eq 'REMEDIATE' })
    $rs  = Tally $rem 'state'
    if((HGet $rs 'SCOPED') -gt 0 -or (HGet $rs 'ANALYZED') -gt 0){ return 'ANALYZE' }
    if((HGet $rs 'TRIAGED') -gt 0 -or (HGet $rs 'REMEDIATED') -gt 0){ return 'REMEDIATE' }
    if((HGet $rs 'VERIFIED') -gt 0){ return 'VALIDATE' }
    $allH = Tally $rows 'state'
    $terminal = (HGet $allH 'TRANSPORTED') + (HGet $allH 'DECOMMISSIONED')
    if($terminal -ge $rows.Count){ return 'DONE' }
    return 'DELIVER'
}

function Get-Gates([string]$dir){
    $g = [ordered]@{ scope_signoff = $true; dryrun_review = $true }   # default ON (safer)
    $p = Join-Path $dir 'campaign.json'
    if(Test-Path -LiteralPath $p){
        try {
            $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            if($j.human_gates){
                if($null -ne $j.human_gates.scope_signoff){ $g.scope_signoff = [bool]$j.human_gates.scope_signoff }
                if($null -ne $j.human_gates.dryrun_review){ $g.dryrun_review = [bool]$j.human_gates.dryrun_review }
            }
        } catch {}
    }
    return $g
}

function Emit-Counts($rows){
    $sH = Tally $rows 'state'; $tH = Tally $rows 'tier'; $dH = Tally $rows 'decision'
    foreach($s in $StateOrder){ $c = HGet $sH $s; if($c -gt 0){ Write-Output "STATE: $s | COUNT: $c" } }
    foreach($t in $TierOrder){  $c = HGet $tH $t; if($c -gt 0){ Write-Output "TIER: $t | COUNT: $c" } }
    foreach($d in $DecisionOrder){ Write-Output "DECISION: $d | COUNT: $(HGet $dH $d)" }
}

function Emit-Metrics($rows){
    $dH = Tally $rows 'decision'; $sH = Tally $rows 'state'
    $dec    = HGet $dH 'DECOMMISSION'
    $scoped = (HGet $dH 'REMEDIATE') + $dec + (HGet $dH 'REVIEW')
    $save   = if($scoped -gt 0){ [int][math]::Round(100.0 * $dec / $scoped) } else { 0 }
    $remTot = (HGet $sH 'REMEDIATED') + (HGet $sH 'VERIFIED') + (HGet $sH 'TRANSPORTED')
    $clean  = (HGet $sH 'VERIFIED') + (HGet $sH 'TRANSPORTED')
    $atc    = if($remTot -gt 0){ [int][math]::Round(100.0 * $clean / $remTot) } else { -1 }
    Write-Output "METRIC: decommission_savings_pct | VALUE: $save"
    Write-Output "METRIC: atc_clean_pct | VALUE: $atc"
}

function Emit-Status($rows,[string]$phase){
    $dH = Tally $rows 'decision'
    Write-Output ("STATUS: PHASE=$phase TOTAL=$(@($rows).Count) REMEDIATE=$(HGet $dH 'REMEDIATE') DECOMMISSION=$(HGet $dH 'DECOMMISSION') REVIEW=$(HGet $dH 'REVIEW')")
}

function Update-Phase([string]$dir,[string]$phase){
    $p = Join-Path $dir 'campaign.json'
    if(-not (Test-Path -LiteralPath $p)){ return }
    try {
        $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $j.phase   = $phase
        $j.updated = (Get-Date).ToString('yyyy-MM-dd')
        Write-Utf8NoBom $p ($j | ConvertTo-Json -Depth 8)
    } catch {}
}

# The pipeline recommender -- encodes the NEXT table from SKILL.md Step 5.
function Recommend-Next($rows,$gates){
    $rows = @($rows)
    if($rows.Count -eq 0){
        return [pscustomobject]@{ skill='/sap-cc-inventory'; reason='no objects inventoried yet'; gate='' }
    }
    $undecided = CW $rows { ([string]$_.decision) -in @('','-') }
    if($undecided -gt 0){
        return [pscustomobject]@{ skill='/sap-cc-usage'; reason="$undecided inventoried object(s) not yet scoped"; gate='' }
    }
    $rem = @($rows | Where-Object { $_.decision -eq 'REMEDIATE' })
    $needAnalyze = CW $rem { $_.state -eq 'SCOPED' }
    if($needAnalyze -gt 0){
        $g = if($gates.scope_signoff){ 'scope_signoff' } else { '' }
        return [pscustomobject]@{ skill='/sap-cc-analyze'; reason="$needAnalyze scoped object(s) await ATC S/4 readiness analysis"; gate=$g }
    }
    $needTriage = CW $rem { $_.state -eq 'ANALYZED' }
    if($needTriage -gt 0){
        return [pscustomobject]@{ skill='/sap-cc-triage'; reason="$needTriage analyzed object(s) await triage"; gate='' }
    }
    $needFix = CW $rem { $_.state -eq 'TRIAGED' -and ([string]$_.tier) -eq 'R1' }
    if($needFix -gt 0){
        $g = if($gates.dryrun_review){ 'dryrun_review' } else { '' }
        return [pscustomobject]@{ skill='/sap-cc-remediate'; reason="$needFix R1 object(s) ready for mechanical remediation (--tier R1, dry-run first)"; gate=$g }
    }
    $needVerify = CW $rem { $_.state -eq 'REMEDIATED' }
    if($needVerify -gt 0){
        return [pscustomobject]@{ skill='/sap-cc-remediate'; reason="$needVerify remediated object(s) await ATC re-check (--recheck)"; gate='' }
    }
    $needTransport = CW $rows { $_.state -eq 'VERIFIED' }
    if($needTransport -gt 0){
        return [pscustomobject]@{ skill='/sap-transport-request'; reason="$needTransport verified object(s) ready to bundle + release"; gate='' }
    }
    $nonTerminal = CW $rows { $_.state -notin @('TRANSPORTED','DECOMMISSIONED') }
    if($nonTerminal -gt 0){
        $review = CW $rows { $_.decision -eq 'REVIEW' }
        $higher = CW $rem  { $_.state -eq 'TRIAGED' -and ([string]$_.tier) -in @('R2','R3','R4') }
        $bits = @()
        if($review -gt 0){ $bits += "$review in REVIEW (operator decision)" }
        if($higher -gt 0){ $bits += "$higher tier R2-R4 (Phase-2 / manual remediation)" }
        $reason = if($bits.Count -gt 0){ $bits -join '; ' } else { 'remaining non-terminal objects need manual attention' }
        return [pscustomobject]@{ skill='MANUAL'; reason=$reason; gate='' }
    }
    return [pscustomobject]@{ skill='DONE'; reason='all objects transported or decommissioned'; gate='' }
}

function Build-Dashboard([string]$dir,$rows,[string]$phase,$patCounts){
    $rows = @($rows)
    $c = $null
    $p = Join-Path $dir 'campaign.json'
    if(Test-Path -LiteralPath $p){ try { $c = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    $src = if($c -and $c.systems){ $c.systems.source_profile }       else { '?' }
    $sbx = if($c -and $c.systems){ $c.systems.sandbox_profile }      else { '?' }
    $chk = if($c -and $c.systems){ $c.systems.check_system_profile } else { '?' }
    $rel = if($c -and $c.target){ ('{0} {1}' -f $c.target.s4_release, $c.target.sp) } else { '?' }
    $cid = if($c -and $c.campaign_id){ $c.campaign_id } else { '?' }
    $today = (Get-Date).ToString('yyyy-MM-dd')

    $dH = Tally $rows 'decision'; $sH = Tally $rows 'state'; $tH = Tally $rows 'tier'
    $dec = HGet $dH 'DECOMMISSION'; $remD = HGet $dH 'REMEDIATE'; $rev = HGet $dH 'REVIEW'
    $scoped = $dec + $remD + $rev
    $save = if($scoped -gt 0){ [int][math]::Round(100.0 * $dec / $scoped) } else { 0 }
    $remTot = (HGet $sH 'REMEDIATED') + (HGet $sH 'VERIFIED') + (HGet $sH 'TRANSPORTED')
    $atc = if($remTot -gt 0){ [int][math]::Round(100.0 * ((HGet $sH 'VERIFIED') + (HGet $sH 'TRANSPORTED')) / $remTot) } else { 0 }

    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("# Migration Campaign $cid - Dashboard ($today)")
    $L.Add("")
    $L.Add("Source $src  ->  Target $rel")
    $L.Add("Sandbox $sbx   Remote-ATC $chk   Phase: $phase")
    $L.Add("")
    $L.Add("## Scope")
    $L.Add("| Decision     | Objects |")
    $L.Add("|--------------|---------|")
    $L.Add("| REMEDIATE    | $remD |")
    $L.Add("| DECOMMISSION | $dec | ($save% retired without remediation)")
    $L.Add("| REVIEW       | $rev |")
    $L.Add("")
    $L.Add("## Pipeline state")
    $L.Add("| State          | Objects |")
    $L.Add("|----------------|---------|")
    foreach($s in $StateOrder){ $L.Add(("| {0} | {1} |" -f $s.PadRight(14), (HGet $sH $s))) }
    $L.Add("")
    $L.Add("## Remediation by tier")
    $L.Add("| Tier | Objects |")
    $L.Add("|------|---------|")
    foreach($t in $TierOrder){ $L.Add("| $t   | $(HGet $tH $t) |") }
    $L.Add("")
    $L.Add("## Top finding patterns")
    if(@($patCounts).Count -gt 0){
        $L.Add("| Pattern | Findings |")
        $L.Add("|---------|----------|")
        foreach($pc in $patCounts){ $L.Add("| $($pc.Name) | $($pc.Count) |") }
    } else {
        $L.Add("_No triaged findings yet._")
    }
    $L.Add("")
    $L.Add("ATC-clean after remediation: $atc%")
    return ($L -join "`r`n") + "`r`n"
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
try {
    if($Action -eq 'init'){
        if([string]::IsNullOrWhiteSpace($CampaignId)){ Write-Output 'ERROR: -CampaignId is required for -Action init'; exit 2 }
        $cjson = Join-Path $CampaignDir 'campaign.json'
        if(Test-Path -LiteralPath $cjson){ Write-Output "EXISTED: campaign at $CampaignDir"; exit 0 }

        foreach($d in @($CampaignDir,
                        (Join-Path $CampaignDir 'findings'),
                        (Join-Path $CampaignDir 'remediation'),
                        (Join-Path $CampaignDir 'reports'),
                        (Join-Path $CampaignDir 'logs'))){
            New-Item -ItemType Directory -Force -Path $d | Out-Null
        }

        $today = (Get-Date).ToString('yyyy-MM-dd')
        $obj = [ordered]@{ schema_version = 1; campaign_id = $CampaignId; created = $today; updated = $today; phase = 'ASSESS' }
        if(-not [string]::IsNullOrWhiteSpace($ProfileJson)){
            try { $prof = $ProfileJson | ConvertFrom-Json } catch { Write-Output "ERROR: -ProfileJson is not valid JSON: $($_.Exception.Message)"; exit 2 }
            foreach($pp in $prof.PSObject.Properties){ $obj[$pp.Name] = $pp.Value }
        }
        Write-Utf8NoBom $cjson (([pscustomobject]$obj) | ConvertTo-Json -Depth 8)
        try { Get-Content -LiteralPath $cjson -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null } catch { Write-Output 'ERROR: campaign.json failed to validate after write'; exit 2 }

        # Real TAB bytes via PowerShell `t (NOT a literal backslash-t), UTF-8 no BOM.
        Write-Utf8NoBom (Join-Path $CampaignDir 'state.tsv') "obj_name`tobj_type`tstate`ttier`tdecision`tupdated_on`r`n"
        Write-Output "INIT: created campaign '$CampaignId' at $CampaignDir (phase=ASSESS)"
        exit 0
    }

    # status / report / next all require an existing workspace
    $cjson = Join-Path $CampaignDir 'campaign.json'
    if(-not (Test-Path -LiteralPath $cjson)){ Write-Output "ERROR: campaign workspace not found at $CampaignDir (run -Action init first)"; exit 2 }

    $rows  = Get-Ledger $CampaignDir
    $phase = Get-Phase $rows

    switch($Action){
        'status' {
            Emit-Counts  $rows
            Emit-Metrics $rows
            Update-Phase $CampaignDir $phase
            Emit-Status  $rows $phase
            if(@($rows).Count -eq 0){ exit 1 }   # gap: nothing inventoried yet
            exit 0
        }
        'report' {
            Emit-Counts  $rows
            Emit-Metrics $rows
            $patCounts = @()
            $patFile = Join-Path $CampaignDir 'findings\findings_triaged.tsv'
            if(Test-Path -LiteralPath $patFile){
                try {
                    $tr = @(Import-Csv -LiteralPath $patFile -Delimiter "`t")
                    $patCounts = @($tr | Where-Object { $_.pattern } | Group-Object pattern | Sort-Object Count -Descending | Select-Object -First 15)
                    foreach($pc in $patCounts){ Write-Output "PATTERN: $($pc.Name) | COUNT: $($pc.Count)" }
                } catch {}
            }
            Update-Phase $CampaignDir $phase
            $dashPath = Join-Path $CampaignDir 'reports\dashboard.md'
            Write-Utf8NoBom $dashPath (Build-Dashboard $CampaignDir $rows $phase $patCounts)
            Write-Output "REPORT: wrote $dashPath"
            Emit-Status $rows $phase
            exit 0
        }
        'next' {
            $gates = Get-Gates $CampaignDir
            $n = Recommend-Next $rows $gates
            $line = "NEXT: skill=$($n.skill) reason=$($n.reason)"
            if($n.gate){ $line += " gate=$($n.gate)" }
            Write-Output $line
            exit 0
        }
    }
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    exit 2
}
