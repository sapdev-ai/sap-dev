# =============================================================================
# sap_sm12_read.ps1  -  /sap-diagnose reader: lock entries (SM12)
#
# Calls ENQUEUE_READ (the live enqueue table is in memory -- NEVER RFC_READ_TABLE
# on SEQG3). Emits one event per lock in the anchor window. Read-only.
# If ENQUEUE_READ is not RFC-enabled on the target system, the reader records a
# clean 'skipped' (the orchestrator continues) and suggests the generic-wrapper
# route (Z_GENERIC_RFC_WRAPPER_TBL) for lock reads.
#
# Tokens: %%RFC_LIB_PS1%% %%DIAG_READER_LIB_PS1%% %%SAP_SERVER%% %%SAP_SYSNR%%
#   %%SAP_CLIENT%% %%SAP_USER%% %%SAP_PASSWORD%% %%SAP_LANGUAGE%%
# Params: -AnchorJson <path> -OutFile <path> [-TopN 200]
# =============================================================================
param([Parameter(Mandatory = $true)][string]$AnchorJson, [Parameter(Mandatory = $true)][string]$OutFile, [int]$TopN = 200)
$ErrorActionPreference = 'Stop'
. "%%RFC_LIB_PS1%%"
. "%%DIAG_READER_LIB_PS1%%"

$a = Read-DiagAnchor $AnchorJson
$dest = Connect-SapRfc -Server "%%SAP_SERVER%%" -Sysnr "%%SAP_SYSNR%%" -Client "%%SAP_CLIENT%%" `
                       -User "%%SAP_USER%%" -Password "%%SAP_PASSWORD%%" -Language "%%SAP_LANGUAGE%%" -DestName "DIAG_SM12"
if (-not $dest) { Write-DiagEvidence 'SM12' 'skipped' 'rfc_connect_failed' @() $false 0 $OutFile; exit 0 }

$enq = $null
try {
    $fn = $dest.Repository.CreateFunction("ENQUEUE_READ")
    if ($a.client) { try { [void]$fn.SetValue("GCLIENT", $a.client) } catch { } }
    $fn.Invoke($dest)
    $enq = $fn.GetTable("ENQ")
} catch {
    Disconnect-SapRfc
    Write-DiagEvidence 'SM12' 'skipped' "ENQUEUE_READ not RFC-callable here ($($_.Exception.Message)); read locks via Z_GENERIC_RFC_WRAPPER_TBL" @() $false 0 $OutFile
    exit 0
}

$events = @(); $idx = 0
$cnt = $enq.RowCount
$lim = [Math]::Min($cnt, $TopN)
for ($i = 0; $i -lt $lim; $i++) {
    $enq.CurrentIndex = $i
    $guname = $enq.GetString("GUNAME"); $gclient = $enq.GetString("GCLIENT")
    $gname = $enq.GetString("GNAME");   $garg = $enq.GetString("GARG")
    $gtcode = $enq.GetString("GTCODE"); $gtdate = $enq.GetString("GTDATE"); $gttime = $enq.GetString("GTTIME")
    $gmode = $enq.GetString("GMODE")
    if ($a.user -and ($guname.Trim() -ne $a.user)) { continue }
    if (-not (Test-InWindow $gtdate $gttime $a.fromTs $a.toTs)) { continue }
    $stt = if ($gttime) { $gttime } else { '000000' }
    $idx++
    $events += New-DiagEvent -Id "SM12-$idx" -Source 'SM12' -Ts ($gtdate + $stt) -Severity 'W' `
        -Client $gclient -User $guname -Tcode $gtcode `
        -ObjectKeys @{ LOCKARG = $garg.Trim() } `
        -MsgText ("Lock on " + $gname.Trim() + " held by " + $guname.Trim() + " (mode " + $gmode.Trim() + ")") `
        -Tech @{ lock_object = $gname.Trim(); arg = $garg.Trim(); mode = $gmode.Trim() } `
        -Drilldown ("SM12 -> " + $gname.Trim() + " -> " + $guname.Trim())
}
Disconnect-SapRfc
Write-DiagEvidence 'SM12' 'ok' "locks=$idx" $events ($cnt -gt $TopN) $cnt $OutFile
