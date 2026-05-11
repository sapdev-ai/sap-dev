# =============================================================================
# sap_function_group_check_state.ps1  -  Check Function Group activation state via
# PROGDIR over NCo 3.1.
#
# Reads PROGDIR rows where NAME = 'SAPL' & FUGR_ID and reports STATE values.
#   A = Active  /  I = Inactive  /  S = Saved
#
# Tokens:
#   %%FUGR_ID%%     Function group name (e.g. ZFUGR001)
#   %%SAP_SERVER%%  %%SAP_SYSNR%%  %%SAP_CLIENT%%
#   %%SAP_USER%%    %%SAP_PASSWORD%%  %%SAP_LANGUAGE%%
#
# Output (last line):
#   STATE=A | STATE=I | STATE=A,I | STATE=A,S
#   NOT_FOUND
#   ERROR:...
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$FUGR_ID       = "%%FUGR_ID%%"

$sProgName = "SAPL" + $FUGR_ID.ToUpper()
Write-Host "INFO: Checking PROGDIR for NAME='$sProgName'"

. "%%RFC_LIB_PS1%%"
$g_dest = Connect-SapRfc -Server   "%%SAP_SERVER%%" `
                         -Sysnr    "%%SAP_SYSNR%%" `
                         -Client   "%%SAP_CLIENT%%" `
                         -User     "%%SAP_USER%%" `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SAPDEV_FUGR"
if (-not $g_dest) { exit 1 }

try {
    $fn = $g_dest.Repository.CreateFunction("RFC_READ_TABLE")
    $fn.SetValue("QUERY_TABLE", "PROGDIR")
    $fn.SetValue("DELIMITER",   "|")
    $flds = $fn.GetTable("FIELDS")
    foreach ($f in @("NAME","STATE")) { $flds.Append() | Out-Null; $flds.SetValue("FIELDNAME", $f) }
    $opts = $fn.GetTable("OPTIONS"); $opts.Append() | Out-Null; $opts.SetValue("TEXT", "NAME = '$sProgName'")
    $fn.Invoke($g_dest)
    $data = $fn.GetTable("DATA")
    if ($data.RowCount -eq 0) {
        Write-Host "NOT_FOUND"
    } else {
        $sStates = ""
        for ($i = 0; $i -lt $data.RowCount; $i++) {
            $data.CurrentIndex = $i
            $wa = $data.GetString("WA")
            $parts = $wa.Split('|')
            $sName  = if ($parts.Length -ge 1) { $parts[0].Trim() } else { "" }
            $sState = if ($parts.Length -ge 2) { $parts[1].Trim() } else { "" }
            Write-Host ("INFO: row " + ($i + 1) + " NAME=$sName STATE=$sState")
            if ($sState -ne "") {
                if ($sStates -eq "")              { $sStates = $sState }
                elseif ($sStates -notmatch [regex]::Escape($sState)) { $sStates = "$sStates,$sState" }
            }
        }
        Write-Host "STATE=$sStates"
    }
} catch {
    Write-Host "ERROR: RFC_READ_TABLE failed on PROGDIR: $($_.Exception.Message)"
    try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
    exit 1
}

try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
exit 0
