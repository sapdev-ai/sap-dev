# =============================================================================
# sap_sm37_read.ps1  -  /sap-diagnose reader: background jobs (SM37 / TBTCO)
#
# Reads TBTCO for jobs in the anchor window, emits one evidence event per job
# (aborted jobs flagged severity A). Read-only RFC. Job-log message drill-down
# (BP_JOBLOG_READ) is a v2 enhancement; MVP surfaces status + program + time.
#
# Tokens (substituted by SKILL.md): %%RFC_LIB_PS1%% %%DIAG_READER_LIB_PS1%%
#   %%SAP_SERVER%% %%SAP_SYSNR%% %%SAP_CLIENT%% %%SAP_USER%% %%SAP_PASSWORD%% %%SAP_LANGUAGE%%
# Params: -AnchorJson <path> -OutFile <path> [-TopN 200]
# =============================================================================
param([Parameter(Mandatory = $true)][string]$AnchorJson, [Parameter(Mandatory = $true)][string]$OutFile, [int]$TopN = 200)
$ErrorActionPreference = 'Stop'
. "%%RFC_LIB_PS1%%"
. "%%DIAG_READER_LIB_PS1%%"

$a = Read-DiagAnchor $AnchorJson

$dest = Connect-SapRfc -Server "%%SAP_SERVER%%" -Sysnr "%%SAP_SYSNR%%" -Client "%%SAP_CLIENT%%" `
                       -User "%%SAP_USER%%" -Password "%%SAP_PASSWORD%%" -Language "%%SAP_LANGUAGE%%" -DestName "DIAG_SM37"
if (-not $dest) { Write-DiagEvidence 'SM37' 'skipped' 'rfc_connect_failed' @() $false 0 $OutFile; exit 0 }

$where = @("STRTDATE GE '$($a.fromDate)' AND STRTDATE LE '$($a.toDate)'")
if ($a.fromDate -eq $a.toDate) {
    # same-day window: bound STRTTIME too so in-window rows are returned by the
    # server (not pushed past the ROWCOUNT cap by the date-only filter).
    $where += "AND STRTTIME GE '$($a.fromTs.Substring(8,6))' AND STRTTIME LE '$($a.toTs.Substring(8,6))'"
}
if ($a.user) { $where += "AND AUTHCKNAM = '$($a.user)'" }
if ($a.job)  { $where += "AND JOBNAME = '$($a.job)'" }
$fields = @('JOBNAME', 'JOBCOUNT', 'STATUS', 'STRTDATE', 'STRTTIME', 'ENDDATE', 'ENDTIME', 'AUTHCKNAM', 'REAXSERVER')

try { $res = Invoke-DiagReadTable $dest 'TBTCO' $where $fields $TopN }
catch { Disconnect-SapRfc; Write-DiagEvidence 'SM37' 'skipped' "tbtco_read_failed: $($_.Exception.Message)" @() $false 0 $OutFile; exit 0 }
Disconnect-SapRfc

$events = @()
$idx = 0
foreach ($r in $res.rows) {
    if (-not (Test-InWindow $r.STRTDATE $r.STRTTIME $a.fromTs $a.toTs)) { continue }
    $stt = if ($r.STRTTIME) { $r.STRTTIME } else { '000000' }
    $ts = $r.STRTDATE + $stt
    switch ($r.STATUS) {
        'A' { $sev = 'A' }   # aborted / cancelled
        'F' { $sev = 'S' }   # finished
        'R' { $sev = 'I' }   # active
        default { $sev = 'I' }
    }
    $idx++
    $events += New-DiagEvent -Id "SM37-$idx" -Source 'SM37' -Ts $ts -Severity $sev `
        -Client $a.client -User $r.AUTHCKNAM `
        -ObjectKeys @{ JOBNAME = $r.JOBNAME } `
        -MsgText ("Job " + $r.JOBNAME + " (count " + $r.JOBCOUNT + ") status=" + $r.STATUS) `
        -Tech @{ jobname = $r.JOBNAME; jobcount = $r.JOBCOUNT; status = $r.STATUS; enddate = $r.ENDDATE; endtime = $r.ENDTIME; server = $r.REAXSERVER } `
        -Drilldown ("SM37 -> " + $r.JOBNAME + " / " + $r.JOBCOUNT)
}
# Aborted jobs are the high-signal events -- surface a hint when present.
$aborted = @($events | Where-Object { $_.severity -eq 'A' }).Count
Write-DiagEvidence 'SM37' 'ok' "aborted=$aborted" $events $res.truncated $res.total $OutFile
