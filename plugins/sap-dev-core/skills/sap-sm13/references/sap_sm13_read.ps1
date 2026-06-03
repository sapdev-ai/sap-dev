# =============================================================================
# sap_sm13_read.ps1  -  /sap-diagnose reader: update-task failures (SM13)
#
# Reads VBHDR (update headers) in the anchor window and joins VBERROR by VBKEY
# to surface failed asynchronous updates (the classic "document didn't post but
# no error on screen" incident). Read-only RFC.
#
# NOTE: VBHDR carries VBDATE (date) but no sub-second time, so SM13 events are
# date-precision. Correlation leans on the engine's 'context' edge (same day +
# user + program/tcode) and business keys rather than the tight temporal window.
#
# Tokens: %%RFC_LIB_PS1%% %%DIAG_READER_LIB_PS1%% %%SAP_SERVER%% %%SAP_SYSNR%%
#   %%SAP_CLIENT%% %%SAP_USER%% %%SAP_PASSWORD%% %%SAP_LANGUAGE%%
# Params: -AnchorJson <path> -OutFile <path> [-TopN 100]
# =============================================================================
param([Parameter(Mandatory = $true)][string]$AnchorJson, [Parameter(Mandatory = $true)][string]$OutFile, [int]$TopN = 100)
$ErrorActionPreference = 'Stop'
. "%%RFC_LIB_PS1%%"
. "%%DIAG_READER_LIB_PS1%%"

$a = Read-DiagAnchor $AnchorJson
$dest = Connect-SapRfc -Server "%%SAP_SERVER%%" -Sysnr "%%SAP_SYSNR%%" -Client "%%SAP_CLIENT%%" `
                       -User "%%SAP_USER%%" -Password "%%SAP_PASSWORD%%" -Language "%%SAP_LANGUAGE%%" -DestName "DIAG_SM13"
if (-not $dest) { Write-DiagEvidence 'SM13' 'skipped' 'rfc_connect_failed' @() $false 0 $OutFile; exit 0 }

$where = @("VBDATE GE '$($a.fromDate)' AND VBDATE LE '$($a.toDate)'")
if ($a.user) { $where += "AND VBUSR = '$($a.user)'" }

try { $hdr = Invoke-DiagReadTable $dest 'VBHDR' $where @('VBKEY', 'VBMANDT', 'VBUSR', 'VBDATE', 'VBTCODE', 'VBREPORT', 'VBSTATE') $TopN }
catch { Disconnect-SapRfc; Write-DiagEvidence 'SM13' 'skipped' "vbhdr_read_failed: $($_.Exception.Message)" @() $false 0 $OutFile; exit 0 }

$events = @(); $idx = 0
foreach ($h in $hdr.rows) {
    $errRows = @()
    try { $e = Invoke-DiagReadTable $dest 'VBERROR' @("VBKEY = '$($h.VBKEY)'") @('VBKEY', 'VBFUNC', 'ARBGB', 'MSGNR', 'VARMSGNO', 'VARMSGVAL') 20; $errRows = @($e.rows) } catch { }
    $hasErr = $errRows.Count -gt 0
    if ($hasErr) {
        $er = $errRows[0]; $sev = 'E'; $fm = $er.VBFUNC
        $mtxt = "Update terminated in $($er.VBFUNC) ($($er.ARBGB) $($er.MSGNR))"
        $mid = $er.ARBGB; $mno = $er.MSGNR
    } else {
        $sev = 'I'; $fm = ''; $mtxt = "Update record (state $($h.VBSTATE))"; $mid = ''; $mno = ''
    }
    $idx++
    $events += New-DiagEvent -Id "SM13-$idx" -Source 'SM13' -Ts ($h.VBDATE + '000000') -Severity $sev `
        -Client $h.VBMANDT -User $h.VBUSR -Tcode $h.VBTCODE -Program $h.VBREPORT `
        -ObjectKeys @{ VBKEY = $h.VBKEY } -MsgId $mid -MsgNo $mno -MsgText $mtxt `
        -Tech @{ vbkey = $h.VBKEY; vbstate = $h.VBSTATE; update_fm = $fm } `
        -Drilldown ("SM13 -> " + $h.VBDATE + " -> " + $h.VBUSR)
}
Disconnect-SapRfc
$errCount = @($events | Where-Object { $_.severity -eq 'E' }).Count
Write-DiagEvidence 'SM13' 'ok' "failed_updates=$errCount" $events $hdr.truncated $hdr.total $OutFile
