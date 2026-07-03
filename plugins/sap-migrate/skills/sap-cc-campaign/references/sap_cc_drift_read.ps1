# sap-cc-campaign companion: detect SOURCE-side DRIFT during a long campaign (RFC).
#
# A brownfield conversion runs for months. While it does, developers keep changing
# the SOURCE (ECC/dev) custom code the campaign already inventoried, analyzed, or
# even REMEDIATED on the sandbox -- so a "done" object can silently change under
# the campaign, and the remediation no longer matches the live source. This
# read-only reader surfaces that drift so `/sap-cc-campaign report` can show it and
# recommend a targeted re-analyze. It does NOT retrofit anything (Phase 2).
#
# WHAT IT READS (source system, read-only):
#   E070  - transport header: TRKORR | TRSTATUS (D/L modifiable, R released) |
#           AS4USER | AS4DATE. Bounded to AS4DATE >= the campaign start date.
#   E071  - transport object entries: TRKORR | PGMID | OBJECT | OBJ_NAME. Joined
#           to the E070 rows above, intersected with the campaign's in-scope
#           objects (state.tsv) -> which tracked objects were touched, by whom,
#           when, in which TR, and whether that TR is still open or released.
#   SMODILOG - modified SAP standard objects (SPAU exposure) -> an advisory count
#           (modifications to SAP objects a conversion will force you to re-adjust).
#
# An object flagged here whose campaign state is REMEDIATED/VERIFIED/TRANSPORTED is
# a RE-ANALYZE candidate: the source moved after we "finished" it.
#
# Usage:
#   sap_cc_drift_read.ps1 -CampaignDir <dir> [-SourceProfile <ref>]
#       [-Since <YYYY-MM-DD>] [-WorkDir <p>] [-SharedDir <p>]
#
# Output grammar (parseable):
#   DRIFT: since=<date> touched=<n> reanalyze=<r> open_trs=<o> released_trs=<x> modlog=<m>
#   DRIFT_OBJ: <name> | TYPE: <t> | TR: <trkorr> | STATUS: <OPEN|RELEASED> | BY: <user> | ON: <date> | STATE: <campaign-state> | REANALYZE: <Y|N>
#   EXPORT: wrote <path>
#   STATUS: OK | NO_DRIFT | ERROR
# Exit: 0 drift found | 1 no drift (clean) | 2 error

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CampaignDir,
    [string]$SourceProfile = '',
    [string]$Since = '',
    [int]$MaxTrs = 500,
    [string]$WorkDir = '',
    [string]$SharedDir = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
function Write-Utf8NoBom([string]$Path,[string]$Text){ $enc = New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllText($Path,$Text,$enc) }
function NormDate([string]$d){ $d="$d".Trim(); if($d.Length -eq 8 -and $d -match '^\d{8}$' -and $d -ne '00000000'){ return $d.Substring(0,4)+'-'+$d.Substring(4,2)+'-'+$d.Substring(6,2) } return '' }

try {
    $cjson = Join-Path $CampaignDir 'campaign.json'
    if (-not (Test-Path -LiteralPath $cjson)) { Write-Output "ERROR: campaign workspace not found at $CampaignDir"; Write-Output 'STATUS: ERROR'; exit 2 }
    $camp = $null; try { $camp = Get-Content -LiteralPath $cjson -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    $srcProf = if (-not [string]::IsNullOrWhiteSpace($SourceProfile)) { $SourceProfile } elseif ($camp -and $camp.systems) { "$($camp.systems.source_profile)" } else { '' }

    # Drift baseline = --Since, else campaign.json created/started date, else 1 year back.
    $sinceDate = $Since.Trim()
    if (-not $sinceDate -and $camp) { foreach($f in @('created','started','started_ts','updated')){ if($camp.$f){ $sinceDate = ("$($camp.$f)").Substring(0,[Math]::Min(10,"$($camp.$f)".Length)); break } } }
    if (-not $sinceDate) { $sinceDate = (Get-Date).AddYears(-1).ToString('yyyy-MM-dd') }
    $sinceDats = ($sinceDate -replace '[^0-9]','')
    if ($sinceDats.Length -ge 8) { $sinceDats = $sinceDats.Substring(0,8) } else { $sinceDats = (Get-Date).AddYears(-1).ToString('yyyyMMdd') }

    if (-not [string]::IsNullOrWhiteSpace($WorkDir)) { $env:SAPDEV_AI_WORK_DIR = $WorkDir }
    if ([string]::IsNullOrWhiteSpace($SharedDir)) { $SharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))) 'sap-dev-core\shared\scripts' }
    foreach ($lib in @('sap_rfc_lib.ps1','sap_settings_lib.ps1','sap_connection_lib.ps1')){ $p = Join-Path $SharedDir $lib; if (-not (Test-Path -LiteralPath $p)) { Write-Output "ERROR: shared lib not found: $p"; Write-Output 'STATUS: ERROR'; exit 2 }; . $p }

    function Resolve-SourceDest([string]$srcProfile){
        if ([string]::IsNullOrWhiteSpace($srcProfile)) { return (Connect-SapRfc -DestName 'CCDRIFT') }
        $m = @(Resolve-SapProfileHint -Hint $srcProfile)
        if ($m.Count -ne 1) { Write-Output "ERROR: source profile '$srcProfile' resolves to $($m.Count) profiles"; return $null }
        $pf = $m[0]; $pw = ''
        if (-not [string]::IsNullOrWhiteSpace("$($pf.password_dpapi)")) { try { $pw = (& (Join-Path $SharedDir 'sap_dpapi.ps1') -Action unprotect -Value "$($pf.password_dpapi)" 2>$null) -as [string]; if ($pw) { $pw = $pw.Trim() } } catch {} }
        if ([string]::IsNullOrWhiteSpace($pw)) { Write-Output "ERROR: source profile '$($pf.description)' has no decryptable password; run /sap-login"; return $null }
        if (-not [string]::IsNullOrWhiteSpace("$($pf.message_server)")) { return (Connect-SapRfc -MessageServer "$($pf.message_server)" -LogonGroup "$($pf.logon_group)" -SystemID "$($pf.system_id)" -Client "$($pf.client)" -User "$($pf.user)" -Password $pw -Language "$($pf.language)" -DestName 'CCDRIFT') }
        return (Connect-SapRfc -Server "$($pf.application_server)" -Sysnr "$($pf.system_number)" -Client "$($pf.client)" -User "$($pf.user)" -Password $pw -Language "$($pf.language)" -DestName 'CCDRIFT')
    }
    function Read-View($dest,[string]$table,[string]$opt,[string[]]$fields){
        $rows=@(); $fn = New-RfcReadTable -Destination $dest -Table $table -Delimiter '|'
        if ($opt) { Add-RfcOption $fn $opt }
        foreach ($f in $fields) { Add-RfcField $fn $f }
        $fn.Invoke($dest); foreach ($r in $fn.GetTable('DATA')) { $rows += ,($r.GetString('WA').Split('|')) }
        return ,$rows
    }

    # In-scope object set + campaign state, from state.tsv.
    $inScope = @{}    # OBJ_NAME(upper) -> state
    $stPath = Join-Path $CampaignDir 'state.tsv'
    if (Test-Path -LiteralPath $stPath) {
        $all = @(Get-Content -LiteralPath $stPath)
        for ($i=1;$i -lt $all.Count;$i++){ $f = $all[$i].Split("`t"); $nm = "$($f[0])".Trim().ToUpper(); if ($nm) { $inScope[$nm] = "$($f[2])".Trim() } }
    }
    if ($inScope.Count -eq 0) { Write-Output 'ERROR: state.tsv empty -- run /sap-cc-inventory + /sap-cc-usage first'; Write-Output 'STATUS: ERROR'; exit 2 }

    $dest = Resolve-SourceDest $srcProf
    if (-not $dest) { Write-Output 'STATUS: ERROR'; exit 2 }

    # 1. Recent TRs (header) since the baseline date. Bounded: with a very wide
    # window this can return thousands of TRs, and step 2 does one E071 read per
    # TR -- so cap to the MaxTrs MOST-RECENT and warn, keeping round-trips bounded.
    $trs = @{}   # TRKORR -> @{ status; user; date }
    $hdr = @(); try { $hdr = Read-View $dest 'E070' ("AS4DATE >= '$sinceDats'") @('TRKORR','TRSTATUS','AS4USER','AS4DATE') } catch { $hdr = @() }
    $capped = $false
    if (@($hdr).Count -gt $MaxTrs) {
        $capped = $true
        $hdr = @($hdr | Sort-Object { "$($_[3])" } -Descending | Select-Object -First $MaxTrs)
    }
    foreach ($h in $hdr) {
        $tk = "$($h[0])".Trim(); if (-not $tk) { continue }
        $trs[$tk] = @{ status = "$($h[1])".Trim(); user = "$($h[2])".Trim(); date = (NormDate $h[3]) }
    }
    if ($capped) { Write-Output "WINDOW_WARN: more than $MaxTrs transports since $sinceDate -- limited to the $MaxTrs most recent. Narrow the window with --since <YYYY-MM-DD> (e.g. the campaign start) or raise --MaxTrs for a full sweep." }

    # 2. Their object entries; intersect with in-scope objects.
    $touched = @()   # each: @{ obj; type; tr; status; user; date; state; reanalyze }
    $seen = @{}
    foreach ($tk in $trs.Keys) {
        $ents = @(); try { $ents = Read-View $dest 'E071' ("TRKORR = '$tk'") @('PGMID','OBJECT','OBJ_NAME') } catch { $ents = @() }
        foreach ($e in $ents) {
            $ot = "$($e[1])".Trim().ToUpper(); $on = "$($e[2])".Trim().ToUpper()
            if (-not $on) { continue }
            if (-not $inScope.ContainsKey($on)) { continue }
            $k = "$on|$tk"; if ($seen.ContainsKey($k)) { continue }; $seen[$k] = $true
            $t = $trs[$tk]
            $stName = $inScope[$on]
            $statusName = if ($t.status -eq 'R') { 'RELEASED' } else { 'OPEN' }
            $re = if ($stName -in @('REMEDIATED','VERIFIED','TRANSPORTED','ANALYZED','TRIAGED')) { 'Y' } else { 'N' }
            $touched += @{ obj=$on; type=$ot; tr=$tk; status=$statusName; user=$t.user; date=$t.date; state=$stName; reanalyze=$re }
        }
    }

    # 3. Advisory: modified SAP standard objects (SPAU exposure).
    $modCount = -1
    try { $ml = Read-View $dest 'SMODILOG' '' @('OBJ_NAME'); $modCount = @($ml).Count } catch { $modCount = -1 }

    Disconnect-SapRfc -Destination $dest

    $openTr = @($touched | Where-Object { $_.status -eq 'OPEN' } | ForEach-Object { $_.tr } | Select-Object -Unique).Count
    $relTr  = @($touched | Where-Object { $_.status -eq 'RELEASED' } | ForEach-Object { $_.tr } | Select-Object -Unique).Count
    $reCnt  = @($touched | Where-Object { $_.reanalyze -eq 'Y' }).Count

    if ($touched.Count -eq 0) {
        Write-Output "DRIFT: since=$sinceDate touched=0 reanalyze=0 open_trs=0 released_trs=0 modlog=$modCount"
        Write-Output 'STATUS: NO_DRIFT'
        exit 1
    }

    $driftDir = Join-Path $CampaignDir 'drift'
    if (-not (Test-Path -LiteralPath $driftDir)) { New-Item -ItemType Directory -Force -Path $driftDir | Out-Null }
    $outPath = Join-Path $driftDir 'drift.tsv'
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("obj_name`tobj_type`ttr`ttr_status`ttouched_by`ttouched_on`tcampaign_state`treanalyze")
    foreach ($d in ($touched | Sort-Object { $_.reanalyze } -Descending)) {
        $L.Add("$($d.obj)`t$($d.type)`t$($d.tr)`t$($d.status)`t$($d.user)`t$($d.date)`t$($d.state)`t$($d.reanalyze)")
        Write-Output "DRIFT_OBJ: $($d.obj) | TYPE: $($d.type) | TR: $($d.tr) | STATUS: $($d.status) | BY: $($d.user) | ON: $($d.date) | STATE: $($d.state) | REANALYZE: $($d.reanalyze)"
    }
    Write-Utf8NoBom $outPath (($L -join "`r`n") + "`r`n")

    Write-Output "DRIFT: since=$sinceDate touched=$($touched.Count) reanalyze=$reCnt open_trs=$openTr released_trs=$relTr modlog=$modCount"
    Write-Output "EXPORT: wrote $outPath"
    Write-Output 'STATUS: OK'
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output 'STATUS: ERROR'
    exit 2
}
