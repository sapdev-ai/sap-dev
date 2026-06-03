# =============================================================================
# sap_slg1_read.ps1  -  /sap-diagnose reader: application log (SLG1 / BALHDR)
#
# Reads BALHDR (application-log headers) in the anchor window. Surfaces logs
# carrying problems (Abort/Error/Warning message counts). Read-only RFC.
# Message-text drill-down (BALDAT is a cluster table -> BAL_* API via the generic
# wrapper) is a v2 enhancement; the header counts + object/subobject/extnumber
# already localize the business-level failure.
#
# Tokens: %%RFC_LIB_PS1%% %%DIAG_READER_LIB_PS1%% %%SAP_SERVER%% %%SAP_SYSNR%%
#   %%SAP_CLIENT%% %%SAP_USER%% %%SAP_PASSWORD%% %%SAP_LANGUAGE%%
# Params: -AnchorJson <path> -OutFile <path> [-TopN 200]
# =============================================================================
param([Parameter(Mandatory = $true)][string]$AnchorJson, [Parameter(Mandatory = $true)][string]$OutFile, [int]$TopN = 200)
$ErrorActionPreference = 'Stop'
. "%%RFC_LIB_PS1%%"
. "%%DIAG_READER_LIB_PS1%%"

function ToInt($s) { $n = 0; [void][int]::TryParse(("$s").Trim(), [ref]$n); return $n }

$a = Read-DiagAnchor $AnchorJson
$dest = Connect-SapRfc -Server "%%SAP_SERVER%%" -Sysnr "%%SAP_SYSNR%%" -Client "%%SAP_CLIENT%%" `
                       -User "%%SAP_USER%%" -Password "%%SAP_PASSWORD%%" -Language "%%SAP_LANGUAGE%%" -DestName "DIAG_SLG1"
if (-not $dest) { Write-DiagEvidence 'SLG1' 'skipped' 'rfc_connect_failed' @() $false 0 $OutFile; exit 0 }

$where = @("ALDATE GE '$($a.fromDate)' AND ALDATE LE '$($a.toDate)'")
if ($a.fromDate -eq $a.toDate) {
    $where += "AND ALTIME GE '$($a.fromTs.Substring(8,6))' AND ALTIME LE '$($a.toTs.Substring(8,6))'"
}
if ($a.user) { $where += "AND ALUSER = '$($a.user)'" }
$fields = @('LOGNUMBER', 'OBJECT', 'SUBOBJECT', 'EXTNUMBER', 'ALDATE', 'ALTIME', 'ALUSER', 'ALPROG', 'ALTCODE', 'PROBCLASS', 'MSG_CNT_A', 'MSG_CNT_E', 'MSG_CNT_W', 'ALTEXT')

try { $res = Invoke-DiagReadTable $dest 'BALHDR' $where $fields $TopN }
catch { Disconnect-SapRfc; Write-DiagEvidence 'SLG1' 'skipped' "balhdr_read_failed: $($_.Exception.Message)" @() $false 0 $OutFile; exit 0 }
Disconnect-SapRfc

$events = @(); $idx = 0
foreach ($r in $res.rows) {
    if (-not (Test-InWindow $r.ALDATE $r.ALTIME $a.fromTs $a.toTs)) { continue }
    $na = ToInt $r.MSG_CNT_A; $ne = ToInt $r.MSG_CNT_E; $nw = ToInt $r.MSG_CNT_W
    if (($na + $ne + $nw) -le 0) { continue }   # only problem-bearing logs
    if ($na -gt 0) { $sev = 'A' } elseif ($ne -gt 0) { $sev = 'E' } else { $sev = 'W' }
    $stt = if ($r.ALTIME) { $r.ALTIME } else { '000000' }
    $okeys = @{}
    $ext = ("$($r.EXTNUMBER)").Trim()
    if ($ext.Length -gt 0 -and $ext.Length -le 60) { $okeys['EXTNUMBER'] = $ext }
    $idx++
    $events += New-DiagEvent -Id "SLG1-$idx" -Source 'SLG1' -Ts ($r.ALDATE + $stt) -Severity $sev `
        -Client $a.client -User $r.ALUSER -Tcode $r.ALTCODE -Program $r.ALPROG `
        -ObjectKeys $okeys `
        -MsgText ("App-log " + $r.OBJECT + "/" + $r.SUBOBJECT + " A=$na E=$ne W=$nw " + $r.ALTEXT) `
        -Tech @{ object = $r.OBJECT; subobject = $r.SUBOBJECT; lognumber = $r.LOGNUMBER; probclass = $r.PROBCLASS; extnumber = $ext } `
        -Drilldown ("SLG1 -> " + $r.OBJECT + "/" + $r.SUBOBJECT + " -> " + $r.ALDATE)
}
Write-DiagEvidence 'SLG1' 'ok' "problem_logs=$idx" $events $res.truncated $res.total $OutFile
