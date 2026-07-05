# =============================================================================
# sap_function_group.ps1  -  Check / Create SAP Function Group via NCo
#
# Checks if a function group exists in TLIBG via RFC_READ_TABLE.
# If it does not exist, creates it via RS_FUNCTION_POOL_INSERT.
#
# Run with **32-bit PowerShell**.
#
# Tokens:
#   %%SAP_APPLICATION_SERVER%%   %%SAP_SYSTEM_NUMBER%%   %%SAP_CLIENT%%
#   %%SAP_USER%%                 %%SAP_PASSWORD%%        %%SAP_LANGUAGE%%
#   %%FUNCTION_GROUP%%   Function group name (Y/Z prefix)
#   %%SHORT_TEXT%%       Short description
#   %%DEVCLASS%%         Development package
#   %%CORRNUM%%          Transport request number
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$sFuncGroup = "%%FUNCTION_GROUP%%".ToUpper()
$sShortText = "%%SHORT_TEXT%%"
$sDevclass  = "%%DEVCLASS%%".ToUpper()
$sCorrnum   = "%%CORRNUM%%".ToUpper()

if ([string]::IsNullOrWhiteSpace($sFuncGroup)) { $sFuncGroup = "ZZSAPDEVFMGAI" }

. "%%RFC_LIB_PS1%%"
$g_dest = Connect-SapRfc -Server   "%%SAP_APPLICATION_SERVER%%" `
                         -Sysnr    "%%SAP_SYSTEM_NUMBER%%" `
                         -Client   "%%SAP_CLIENT%%" `
                         -User     "%%SAP_USER%%" `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SAPDEV_FG"
if (-not $g_dest) { Write-Host "RESULT_STATUS: ERROR"; exit 1 }

# --- Step 1: Check TLIBG ----------------------------------------------------
Write-Host "INFO: Checking function group $sFuncGroup in TLIBG..."
try {
    $fn = $g_dest.Repository.CreateFunction("RFC_READ_TABLE")
    $fn.SetValue("QUERY_TABLE", "TLIBG")
    $fn.SetValue("DELIMITER",   "|")
    $fn.SetValue("ROWCOUNT",    1)
    $opts = $fn.GetTable("OPTIONS"); $opts.Append() | Out-Null; $opts.SetValue("TEXT", "AREA = '$sFuncGroup'")
    $flds = $fn.GetTable("FIELDS"); $flds.Append() | Out-Null; $flds.SetValue("FIELDNAME", "AREA")
    $fn.Invoke($g_dest)
    $nRows = $fn.GetTable("DATA").RowCount
} catch {
    Write-Host "ERROR: RFC_READ_TABLE on TLIBG failed: $($_.Exception.Message)"
    Write-Host "RESULT_STATUS: ERROR"
    try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
    exit 1
}

if ($nRows -gt 0) {
    Write-Host "INFO: Function group $sFuncGroup already exists."
    Write-Host "RESULT_FG: $sFuncGroup"
    Write-Host "RESULT_STATUS: EXISTS"
    try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
    exit 0
}

# --- Step 2: Create via RS_FUNCTION_POOL_INSERT -----------------------------
Write-Host "INFO: Function group $sFuncGroup does not exist. Creating..."
try {
    $fnIns = $g_dest.Repository.CreateFunction("RS_FUNCTION_POOL_INSERT")
    $fnIns.SetValue("FUNCTION_POOL", $sFuncGroup)
    $fnIns.SetValue("SHORT_TEXT",    $sShortText)
    $fnIns.SetValue("DEVCLASS",      $sDevclass)
    $fnIns.SetValue("CORRNUM",       $sCorrnum)
    # Transport registration: SUPPRESS_CORR_CHECK defaults to 'X' (suppress), which
    # creates the FG with a TADIR/package but leaves it OFF-transport (no E071 lock -
    # the reason RFC-created dev FGs like ZFGDEVAI were off the TR). With a real TR
    # (CORRNUM) and a transportable (non-$TMP) package, set it blank so the correction
    # check records R3TR FUGR in the request; for a local/$TMP FG keep 'X' (and never
    # leave it blank without a CORRNUM, which would prompt -> hang over RFC).
    if ((-not [string]::IsNullOrWhiteSpace($sCorrnum)) -and ($sDevclass -ne '$TMP')) {
        $fnIns.SetValue("SUPPRESS_CORR_CHECK", " ")
    } else {
        $fnIns.SetValue("SUPPRESS_CORR_CHECK", "X")
    }
    $fnIns.Invoke($g_dest)
    Write-Host "INFO: Function group $sFuncGroup created successfully."
    Write-Host "RESULT_FG: $sFuncGroup"
    Write-Host "RESULT_STATUS: CREATED"
} catch {
    Write-Host "ERROR: RS_FUNCTION_POOL_INSERT failed: $($_.Exception.Message)"
    Write-Host "RESULT_FG: $sFuncGroup"
    Write-Host "RESULT_STATUS: ERROR"
    try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
    exit 1
}

try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
exit 0
