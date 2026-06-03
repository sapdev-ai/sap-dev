# sap-cc-usage companion: read ABAP Call Monitor usage DIRECTLY via RFC.
#
# Reads aggregated usage from the SOURCE system's ABAP Call Monitor / SUSG
# aggregation and writes a standard usage-export TSV (object_name, exec_count,
# last_used) that /sap-cc-usage ingests via its FILE path. This is the "direct
# SCMON/UPL read" that replaces hand-exporting usage.
#
# DATA MODEL (verified live, S/4HANA 1909):
#   SUSG_V_DATA  - DB view: aggregated usage. OBJ_NAME (repo object) | OBJ_TYPE |
#                  COUNTER (exec count, DEC) | LAST_USED (DATS). This is the
#                  canonical decommissioning source (persisted by tx SUSG).
#   SUSG_ADMIN   - aggregation runs: DATE_FROM | DATE_TO | DAYS_AVAILABLE |
#                  DAYS_MISSING  -> the OBSERVATION WINDOW.
#   SCMON_VDATA  - DB view: raw Call Monitor slices (fallback when SUSG not
#                  aggregated): OBJ_NAME | COUNTER | SLICESTART | SLICEEND.
#   On NW 7.52+/S4, SCMON subsumes UPL, so SCMON and UPL read the same path.
#
# SAFETY (the load-bearing rule): NO monitoring data must NEVER be read as
# "everything is unused". If SUSG + SCMON are both empty, we emit STATUS:NO_DATA
# and write no export -- /sap-cc-usage then defaults every object to REMEDIATE.
# A short observation window emits WINDOW_WARN (short windows miss period-end /
# year-end jobs and OVER-flag objects as unused).
#
# Usage:
#   sap_cc_scmon_read.ps1 -CampaignDir <dir> [-SourceProfile <ref>]
#       [-OutFile <path>] [-Namespaces 'Z,Y'] [-Source AUTO|SUSG|SCMON]
#       [-MinWindowDays 365] [-WorkDir <p>] [-SharedDir <p>]
#
# Output grammar (parseable):
#   SCMON: source=<SUSG|SCMON|NONE> window=<from>..<to> days_available=<n> days_missing=<n> objects=<n> rows=<n>
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
    [ValidateSet('AUTO','SUSG','SCMON')][string]$Source = 'AUTO',
    [int]$MinWindowDays = 365,
    [string]$WorkDir = '',
    [string]$SharedDir = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Utf8NoBom([string]$Path,[string]$Text){
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Text,$enc)
}
# DATS 'YYYYMMDD' -> 'YYYY-MM-DD'; blank/zero -> ''.
function NormDate([string]$d){
    $d = "$d".Trim()
    if ($d.Length -eq 8 -and $d -match '^\d{8}$' -and $d -ne '00000000') {
        return $d.Substring(0,4) + '-' + $d.Substring(4,2) + '-' + $d.Substring(6,2)
    }
    return ''
}

try {
    $cjson = Join-Path $CampaignDir 'campaign.json'
    if (-not (Test-Path -LiteralPath $cjson)) { Write-Output "ERROR: campaign workspace not found at $CampaignDir (run /sap-cc-campaign init)"; Write-Output 'STATUS: ERROR'; exit 2 }
    $camp = $null
    try { $camp = Get-Content -LiteralPath $cjson -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    $srcProf = if (-not [string]::IsNullOrWhiteSpace($SourceProfile)) { $SourceProfile }
               elseif ($camp -and $camp.systems) { "$($camp.systems.source_profile)" } else { '' }
    if ([string]::IsNullOrWhiteSpace($OutFile)) { $OutFile = Join-Path $CampaignDir 'usage_scmon_export.tsv' }

    # --- load shared libs + resolve the source RFC destination (mirrors /sap-cc-inventory) ---
    if (-not [string]::IsNullOrWhiteSpace($WorkDir)) { $env:SAPDEV_AI_WORK_DIR = $WorkDir }
    if ([string]::IsNullOrWhiteSpace($SharedDir)) {
        $SharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))) 'sap-dev-core\shared\scripts'
    }
    foreach ($lib in @('sap_rfc_lib.ps1','sap_settings_lib.ps1','sap_connection_lib.ps1')){
        $p = Join-Path $SharedDir $lib
        if (-not (Test-Path -LiteralPath $p)) { Write-Output "ERROR: shared lib not found: $p"; Write-Output 'STATUS: ERROR'; exit 2 }
        . $p
    }

    function Resolve-SourceDest([string]$srcProfile){
        if ([string]::IsNullOrWhiteSpace($srcProfile)) { return (Connect-SapRfc -DestName 'CCUSG') }
        $m = @(Resolve-SapProfileHint -Hint $srcProfile)
        if ($m.Count -eq 0) { Write-Output "ERROR: source profile '$srcProfile' not found in the connection store (run /sap-login --list)"; return $null }
        if ($m.Count -gt 1) { Write-Output "ERROR: source profile '$srcProfile' is ambiguous ($($m.Count) matches); use SID/CLIENT or the UUID"; return $null }
        $p = $m[0]; $pw = ''
        if (-not [string]::IsNullOrWhiteSpace("$($p.password_dpapi)")) {
            try { $pw = (& (Join-Path $SharedDir 'sap_dpapi.ps1') -Action unprotect -Value "$($p.password_dpapi)" 2>$null) -as [string]; if ($pw) { $pw = $pw.Trim() } } catch {}
        }
        if ([string]::IsNullOrWhiteSpace($pw)) { Write-Output "ERROR: source profile '$($p.description)' has no decryptable password; run /sap-login to save it"; return $null }
        if (-not [string]::IsNullOrWhiteSpace("$($p.message_server)")) {
            return (Connect-SapRfc -MessageServer "$($p.message_server)" -LogonGroup "$($p.logon_group)" -SystemID "$($p.system_id)" -Client "$($p.client)" -User "$($p.user)" -Password $pw -Language "$($p.language)" -DestName 'CCUSG')
        }
        return (Connect-SapRfc -Server "$($p.application_server)" -Sysnr "$($p.system_number)" -Client "$($p.client)" -User "$($p.user)" -Password $pw -Language "$($p.language)" -DestName 'CCUSG')
    }

    # Read selected fields of a transparent table / DB view; returns array of split rows.
    function Read-View($dest,[string]$table,[string]$opt,[string[]]$fields){
        $rows = @()
        $fn = New-RfcReadTable -Destination $dest -Table $table -Delimiter '|'
        if ($opt) { Add-RfcOption $fn $opt }
        foreach ($f in $fields) { Add-RfcField $fn $f }
        $fn.Invoke($dest)
        $d = $fn.GetTable('DATA')
        foreach ($r in $d) { $rows += ,($r.GetString('WA').Split('|')) }
        return ,$rows
    }

    $dest = Resolve-SourceDest $srcProf
    if (-not $dest) { Write-Output 'STATUS: ERROR'; exit 2 }

    $nsList = @($Namespaces.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($nsList.Count -eq 0) { $nsList = @('Z','Y') }

    $map = @{}            # OBJ_NAME(upper) -> @{ exec=[decimal]; last='YYYY-MM-DD' }
    $srcUsed = 'NONE'; $winFrom = ''; $winTo = ''; $daysAvail = -1; $daysMissing = -1; $rowsRead = 0

    # Accumulate one row into $map. $ci = counter field index; $li = last-date index (-1 = none).
    function Add-Row($r,[int]$ci,[int]$li){
        $nm = "$($r[0])".Trim().ToUpper(); if (-not $nm) { return }
        $cnt = [decimal]0
        $digits = ("$($r[$ci])" -replace '[^0-9]','')
        if ($digits) { [void][decimal]::TryParse($digits, [ref]$cnt) }
        $lst = if ($li -ge 0 -and $li -lt $r.Length) { NormDate $r[$li] } else { '' }
        if ($map.ContainsKey($nm)) {
            $map[$nm].exec += $cnt
            if ($lst -and ($lst -gt $map[$nm].last)) { $map[$nm].last = $lst }
        } else {
            $map[$nm] = @{ exec = $cnt; last = $lst }
        }
    }

    # --- 1. SUSG aggregated (canonical) -------------------------------------
    if ($Source -ne 'SCMON') {
        $admin = @()
        try { $admin = Read-View $dest 'SUSG_ADMIN' '' @('DATE_FROM','DATE_TO','DAYS_AVAILABLE','DAYS_MISSING') } catch { $admin = @() }
        if (@($admin).Count -gt 0) {
            $froms = @(); $tos = @(); $da = 0; $dm = 0
            foreach ($a in $admin) {
                $f = NormDate $a[0]; $t = NormDate $a[1]
                if ($f) { $froms += $f }; if ($t) { $tos += $t }
                $n = 0; [void][int]::TryParse("$($a[2])", [ref]$n); if ($n -gt $da) { $da = $n }
                $n = 0; [void][int]::TryParse("$($a[3])", [ref]$n); if ($n -gt $dm) { $dm = $n }
            }
            if ($froms.Count) { $winFrom = (@($froms) | Sort-Object)[0] }
            if ($tos.Count)   { $winTo   = (@($tos)   | Sort-Object)[-1] }
            $daysAvail = $da; $daysMissing = $dm
        }
        foreach ($ns in $nsList) {
            $rs = @(); try { $rs = Read-View $dest 'SUSG_V_DATA' ("OBJ_NAME LIKE '$ns%'") @('OBJ_NAME','OBJ_TYPE','COUNTER','LAST_USED') } catch { $rs = @() }
            foreach ($r in $rs) { Add-Row $r 2 3 }
            $rowsRead += @($rs).Count
        }
        if ($map.Count -gt 0) { $srcUsed = 'SUSG' }
    }

    # --- 2. SCMON raw fallback (when SUSG not aggregated) -------------------
    if ($map.Count -eq 0 -and $Source -ne 'SUSG') {
        foreach ($ns in $nsList) {
            $rs = @(); try { $rs = Read-View $dest 'SCMON_VDATA' ("OBJ_NAME LIKE '$ns%'") @('OBJ_NAME','COUNTER','SLICESTART','SLICEEND') } catch { $rs = @() }
            foreach ($r in $rs) {
                Add-Row $r 1 3                       # SLICEEND as last-used proxy
                $sf = NormDate $r[2]; $se = NormDate $r[3]
                if ($sf -and (-not $winFrom -or $sf -lt $winFrom)) { $winFrom = $sf }
                if ($se -and (-not $winTo   -or $se -gt $winTo))   { $winTo   = $se }
            }
            $rowsRead += @($rs).Count
        }
        if ($map.Count -gt 0) { $srcUsed = 'SCMON' }
    }

    # --- 3. No data -> SAFE path (never "all unused") -----------------------
    if ($map.Count -eq 0) {
        Write-Output "SCMON: source=NONE window=$winFrom..$winTo days_available=$daysAvail days_missing=$daysMissing objects=0 rows=$rowsRead"
        Write-Output "WARN: ABAP Call Monitor (SCMON) / SUSG returned no usage data on this system. Monitoring is likely not active or never aggregated. Usage cannot be derived -- /sap-cc-usage will default every object to REMEDIATE (safe; nothing decommissioned). Activate SCMON (tx SCMON) and aggregate via SUSG over >= $MinWindowDays days before relying on decommission decisions."
        Write-Output 'STATUS: NO_DATA'
        exit 1
    }

    # --- 4. Write the usage export (object_name, exec_count, last_used) ------
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("object_name`texec_count`tlast_used")
    foreach ($k in (@($map.Keys) | Sort-Object)) {
        $e = [long]$map[$k].exec
        $out.Add("$k`t$e`t$($map[$k].last)")
    }
    Write-Utf8NoBom $OutFile (($out -join "`r`n") + "`r`n")

    Write-Output "SCMON: source=$srcUsed window=$winFrom..$winTo days_available=$daysAvail days_missing=$daysMissing objects=$($map.Count) rows=$rowsRead"

    # --- 5. Window-honesty warnings ----------------------------------------
    if ($winFrom -and $winTo) {
        $span = -1
        try { $span = ([datetime]::ParseExact($winTo,'yyyy-MM-dd',$null) - [datetime]::ParseExact($winFrom,'yyyy-MM-dd',$null)).Days } catch {}
        if ($span -ge 0 -and $span -lt $MinWindowDays) {
            Write-Output "WINDOW_WARN: observed window is $span day(s) ($winFrom..$winTo) < $MinWindowDays -- short windows MISS period-end/quarter-end/year-end jobs, so unused-flagging will OVER-decommission. Treat DECOMMISSION candidates as REVIEW until a >= $MinWindowDays-day window is available."
        }
    } else {
        Write-Output "WINDOW_WARN: observation window is unknown (no SUSG aggregation dates). Cannot confirm coverage length -- treat unused-flagging cautiously."
    }
    if ($daysMissing -gt 0) { Write-Output "WINDOW_WARN: $daysMissing day(s) missing from the aggregation window -- monitoring coverage has gaps." }

    Write-Output "EXPORT: wrote $OutFile"
    Write-Output 'STATUS: OK'
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output 'STATUS: ERROR'
    exit 2
}
