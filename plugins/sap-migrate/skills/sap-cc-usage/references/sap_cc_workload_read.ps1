# sap-cc-usage companion: read ST03N/SWNC WORKLOAD as a COARSE usage proxy via RFC.
#
# The fallback for systems where SCMON/UPL was never activated (so
# sap_cc_scmon_read.ps1 returns NO_DATA and every object defaults to REMEDIATE).
# It reads the SAP workload monitor (tx ST03N) aggregates and writes the same
# usage-export TSV (object_name, exec_count, last_used) that /sap-cc-usage
# ingests via its FILE path -- stamped usage_source=WORKLOAD.
#
# DATA MODEL:
#   SWNC_GET_WORKLOAD_STATISTIC (remote-enabled) -> EXPORTING table TCDET
#   ("transaction profile", the ST03N per-entry aggregate). Each row's ENTRY_ID
#   is a transaction code OR a directly-started report; COUNT is the step count.
#   We call it once per month over the retained window and SUM COUNT per ENTRY_ID.
#   Z/Y tcodes are resolved to their program (TSTC.PGMNA); a Z/Y ENTRY_ID that is
#   already a program name is used as-is. Both map to PROG repo objects.
#
# COVERAGE + CONFIDENCE (the load-bearing honesty rules):
#   * WORKLOAD is a POSITIVE-ONLY, LOW-confidence signal. It can CONFIRM that an
#     executable ran; it can NEVER assert an object is unused. Only executables
#     (reports + tcode programs) ever appear in ST03N -- a custom CLASS / FM /
#     TABLE / structure is INVISIBLE here, so its absence means "unknown", not
#     "unused". The engine enforces this: for usage_source=WORKLOAD an object
#     absent from this export is UNKNOWN -> REMEDIATE (never decommissioned),
#     except PROG objects which may become REVIEW candidates (never auto-
#     DECOMMISSION). This reader therefore lists only the objects it SAW run.
#   * NO data must NEVER read as "everything unused": empty -> STATUS:NO_DATA and
#     no export (the engine then defaults every object to REMEDIATE).
#   * ST03N retention is short (day-level often ~2 weeks; month/week kept longer)
#     -> a WINDOW_WARN is always emitted so the operator treats absence cautiously.
#
# Usage:
#   sap_cc_workload_read.ps1 -CampaignDir <dir> [-SourceProfile <ref>]
#       [-OutFile <path>] [-Namespaces 'Z,Y'] [-Months 12] [-WorkDir <p>] [-SharedDir <p>]
#
# Output grammar (parseable):
#   WORKLOAD: months_scanned=<n> months_with_data=<n> entries=<e> objects=<o> mapped_via_tstc=<t>
#   WINDOW_WARN: <text>
#   EXPORT: wrote <path>
#   WARN: <text>
#   STATUS: OK | NO_DATA | ERROR
# Exit: 0 ok (export written) | 1 no usage data (safe) | 2 error

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CampaignDir,
    [string]$SourceProfile = '',
    [string]$OutFile = '',
    [string]$Namespaces = 'Z,Y',
    [int]$Months = 12,
    [string]$WorkDir = '',
    [string]$SharedDir = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Utf8NoBom([string]$Path,[string]$Text){
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Text,$enc)
}

try {
    $cjson = Join-Path $CampaignDir 'campaign.json'
    if (-not (Test-Path -LiteralPath $cjson)) { Write-Output "ERROR: campaign workspace not found at $CampaignDir (run /sap-cc-campaign init)"; Write-Output 'STATUS: ERROR'; exit 2 }
    $camp = $null
    try { $camp = Get-Content -LiteralPath $cjson -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    $srcProf = if (-not [string]::IsNullOrWhiteSpace($SourceProfile)) { $SourceProfile }
               elseif ($camp -and $camp.systems) { "$($camp.systems.source_profile)" } else { '' }
    if ([string]::IsNullOrWhiteSpace($OutFile)) { $OutFile = Join-Path $CampaignDir 'usage_workload_export.tsv' }

    if (-not [string]::IsNullOrWhiteSpace($WorkDir)) { $env:SAPDEV_AI_WORK_DIR = $WorkDir }
    if ([string]::IsNullOrWhiteSpace($SharedDir)) {
        $SharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))) 'sap-dev-core\shared\scripts'
    }
    foreach ($lib in @('sap_rfc_lib.ps1','sap_settings_lib.ps1','sap_connection_lib.ps1')){
        $p = Join-Path $SharedDir $lib
        if (-not (Test-Path -LiteralPath $p)) { Write-Output "ERROR: shared lib not found: $p"; Write-Output 'STATUS: ERROR'; exit 2 }
        . $p
    }

    # Resolve the source RFC destination (mirrors sap_cc_scmon_read.ps1).
    function Resolve-SourceDest([string]$srcProfile){
        if ([string]::IsNullOrWhiteSpace($srcProfile)) { return (Connect-SapRfc -DestName 'CCWL') }
        $m = @(Resolve-SapProfileHint -Hint $srcProfile)
        if ($m.Count -eq 0) { Write-Output "ERROR: source profile '$srcProfile' not found in the connection store (run /sap-login --list)"; return $null }
        if ($m.Count -gt 1) { Write-Output "ERROR: source profile '$srcProfile' is ambiguous ($($m.Count) matches); use SID/CLIENT or the UUID"; return $null }
        $pf = $m[0]; $pw = ''
        if (-not [string]::IsNullOrWhiteSpace("$($pf.password_dpapi)")) {
            try { $pw = (& (Join-Path $SharedDir 'sap_dpapi.ps1') -Action unprotect -Value "$($pf.password_dpapi)" 2>$null) -as [string]; if ($pw) { $pw = $pw.Trim() } } catch {}
        }
        if ([string]::IsNullOrWhiteSpace($pw)) { Write-Output "ERROR: source profile '$($pf.description)' has no decryptable password; run /sap-login to save it"; return $null }
        if (-not [string]::IsNullOrWhiteSpace("$($pf.message_server)")) {
            return (Connect-SapRfc -MessageServer "$($pf.message_server)" -LogonGroup "$($pf.logon_group)" -SystemID "$($pf.system_id)" -Client "$($pf.client)" -User "$($pf.user)" -Password $pw -Language "$($pf.language)" -DestName 'CCWL')
        }
        return (Connect-SapRfc -Server "$($pf.application_server)" -Sysnr "$($pf.system_number)" -Client "$($pf.client)" -User "$($pf.user)" -Password $pw -Language "$($pf.language)" -DestName 'CCWL')
    }

    $dest = Resolve-SourceDest $srcProf
    if (-not $dest) { Write-Output 'STATUS: ERROR'; exit 2 }

    $nsList = @($Namespaces.Split(',') | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
    if ($nsList.Count -eq 0) { $nsList = @('Z','Y') }
    function In-Namespace([string]$name){
        $u = "$name".Trim().ToUpper(); if (-not $u) { return $false }
        foreach ($ns in $nsList) { if ($u.StartsWith($ns)) { return $true } }
        return $false
    }

    # --- TSTC map: Z/Y tcode -> program (PGMNA) -----------------------------
    $tcodeToProg = @{}
    foreach ($ns in $nsList) {
        try {
            $fn = New-RfcReadTable -Destination $dest -Table 'TSTC' -Delimiter '|'
            Add-RfcOption $fn "TCODE LIKE '$ns%'"
            Add-RfcField $fn 'TCODE'; Add-RfcField $fn 'PGMNA'
            $fn.Invoke($dest)
            foreach ($r in $fn.GetTable('DATA')) {
                $parts = $r.GetString('WA').Split('|')
                $tc = "$($parts[0])".Trim().ToUpper(); $pg = "$($parts[1])".Trim().ToUpper()
                if ($tc -and $pg) { $tcodeToProg[$tc] = $pg }
            }
        } catch {}
    }

    # --- Discover the ENTRY_ID / COUNT columns of TCDET once (introspection) --
    # SWNCGL_T_AGGTCDET line type varies slightly by release; pick by name.
    $entryCol = $null; $countCol = $null
    $monthsScanned = 0; $monthsWithData = 0; $entriesSeen = 0
    $map = @{}   # PROG name (upper) -> @{ exec=[decimal]; last='YYYY-MM-DD' }

    $now = Get-Date
    for ($mi = 0; $mi -lt $Months; $mi++) {
        $d = $now.AddMonths(-$mi)
        $periodStart = ('{0:D4}{1:D2}01' -f $d.Year, $d.Month)   # YYYYMM01 (DATS)
        $lastProxy = ('{0:D4}-{1:D2}-01' -f $d.Year, $d.Month)
        $monthsScanned++
        $fn = $null
        try {
            $fn = $dest.Repository.CreateFunction('SWNC_GET_WORKLOAD_STATISTIC')
            $fn.SetValue('PERIODTYPE','M')
            $fn.SetValue('PERIODSTRT',$periodStart)
            try { $fn.SetValue('SUMMARY_ONLY','X') } catch {}
            $fn.Invoke($dest)
        } catch { continue }
        $tc = $null
        try { $tc = $fn.GetTable('TCDET') } catch { $tc = $null }
        if (-not $tc -or $tc.RowCount -eq 0) { continue }

        if (-not $entryCol) {
            $names = @(); foreach ($col in $tc.Metadata) { $names += $col.Name }
            foreach ($cand in @('ENTRY_ID','ACCOUNT','TCODE','REPORT')) { if ($names -contains $cand) { $entryCol = $cand; break } }
            foreach ($cand in @('COUNT','ENTRY_CNT','CNT')) { if ($names -contains $cand) { $countCol = $cand; break } }
            if (-not $entryCol -or -not $countCol) {
                Write-Output ("WARN: could not locate ENTRY_ID/COUNT columns in TCDET (fields: " + ($names -join ',') + ")")
                break
            }
        }

        $hadRow = $false
        foreach ($row in $tc) {
            $eid = "$($row.GetString($entryCol))".Trim().ToUpper()
            if (-not (In-Namespace $eid)) { continue }
            $cnt = [decimal]0; $digits = ("$($row.GetString($countCol))" -replace '[^0-9]',''); if ($digits) { [void][decimal]::TryParse($digits,[ref]$cnt) }
            if ($cnt -le 0) { continue }
            # Resolve to a PROG object: Z/Y tcode -> its program; else the entry is
            # itself a report/program name.
            $prog = if ($tcodeToProg.ContainsKey($eid)) { $tcodeToProg[$eid] } else { $eid }
            if (-not (In-Namespace $prog)) { continue }   # tcode pointing at an SAP program -> not custom code
            $entriesSeen++
            if ($map.ContainsKey($prog)) {
                $map[$prog].exec += $cnt
                if ($lastProxy -gt $map[$prog].last) { $map[$prog].last = $lastProxy }
            } else {
                $map[$prog] = @{ exec = $cnt; last = $lastProxy }
            }
            $hadRow = $true
        }
        if ($hadRow) { $monthsWithData++ }
    }

    $tstcCount = $tcodeToProg.Count
    Disconnect-SapRfc -Destination $dest

    if ($map.Count -eq 0) {
        Write-Output "WORKLOAD: months_scanned=$monthsScanned months_with_data=0 entries=0 objects=0 mapped_via_tstc=$tstcCount"
        Write-Output "WARN: the SAP workload monitor (ST03N / SWNC) returned no custom-code ($($nsList -join '/')) entries over the last $Months month(s). Either the workload has no custom executables in the retained window, or the collector has no data. Usage cannot be derived -- /sap-cc-usage will default every object to REMEDIATE (safe; nothing decommissioned)."
        Write-Output 'STATUS: NO_DATA'
        exit 1
    }

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("object_name`texec_count`tlast_used")
    foreach ($k in (@($map.Keys) | Sort-Object)) {
        $e = [long]$map[$k].exec
        $out.Add("$k`t$e`t$($map[$k].last)")
    }
    Write-Utf8NoBom $OutFile (($out -join "`r`n") + "`r`n")

    Write-Output "WORKLOAD: months_scanned=$monthsScanned months_with_data=$monthsWithData entries=$entriesSeen objects=$($map.Count) mapped_via_tstc=$tstcCount"
    Write-Output "WINDOW_WARN: WORKLOAD is a COARSE, LOW-confidence, positive-only signal -- it confirms which custom reports/tcode-programs RAN, but CANNOT prove an object is unused (ST03N retention is short and never lists classes/FMs/tables). Absence here is treated as UNKNOWN (-> REMEDIATE), and unseen PROG objects as REVIEW at most -- never auto-DECOMMISSION. Prefer SCMON/SUSG with a >= 12-month window for decommission decisions."
    Write-Output "EXPORT: wrote $OutFile"
    Write-Output 'STATUS: OK'
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output 'STATUS: ERROR'
    exit 2
}
