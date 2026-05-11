# =============================================================================
# sap_check_package.ps1  -  Check if SAP package exists via RFC_READ_TABLE on TDEVC
#
# Run with **32-bit PowerShell**.
#
# Tokens:
#   %%SAP_APPLICATION_SERVER%%  %%SAP_SYSTEM_NUMBER%%  %%SAP_CLIENT%%
#   %%SAP_USER%%  %%SAP_PASSWORD%%  %%SAP_LANGUAGE%%
#   %%PACKAGE%%  Package name to check (e.g. ZCMDEVAI)
#
# Output:
#   PACKAGE_EXISTS: <name>
#   PACKAGE_NOT_FOUND: <name>
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$PACKAGE_NAME  = "%%PACKAGE%%"

. "%%RFC_LIB_PS1%%"
$g_dest = Connect-SapRfc -Server   "%%SAP_APPLICATION_SERVER%%" `
                         -Sysnr    "%%SAP_SYSTEM_NUMBER%%" `
                         -Client   "%%SAP_CLIENT%%" `
                         -User     "%%SAP_USER%%" `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SAPDEV_PKG"
if (-not $g_dest) { exit 1 }

try {
    $fn = $g_dest.Repository.CreateFunction("RFC_READ_TABLE")
    $fn.SetValue("QUERY_TABLE", "TDEVC")
    $fn.SetValue("DELIMITER",   "|")
    $fn.SetValue("ROWCOUNT",    1)
    $opts = $fn.GetTable("OPTIONS"); $opts.Append() | Out-Null; $opts.SetValue("TEXT", "DEVCLASS = '$PACKAGE_NAME'")
    $flds = $fn.GetTable("FIELDS"); $flds.Append() | Out-Null; $flds.SetValue("FIELDNAME", "DEVCLASS")
    $fn.Invoke($g_dest)
    if ($fn.GetTable("DATA").RowCount -gt 0) { Write-Host "PACKAGE_EXISTS: $PACKAGE_NAME" }
    else                                     { Write-Host "PACKAGE_NOT_FOUND: $PACKAGE_NAME" }
} catch {
    # BUGFIX (sap-dev-init 2026-05-11): the previous catch swallowed every
    # non-listed RFC failure as PACKAGE_NOT_FOUND, producing false negatives
    # when the actual cause was a transient RFC failure (connection drop,
    # busy work process, codepage issue, ...). The orchestrator then went on
    # to "create" a package that was already there and got confused by the
    # SE21 "already exists" message. Surface every unexpected failure as a
    # distinguishable RFC_ERROR so the caller can retry / abort instead of
    # silently misreporting absence.
    $msg = $_.Exception.Message
    if ($msg -match "DATA_BUFFER_EXCEEDED|NOT_AUTHORIZED") {
        Write-Host "ERROR: $msg"
    } elseif ($msg -match "TABLE_NOT_AVAILABLE|TSV_TNEW_PAGE_ALLOC_FAILED") {
        # RFC_READ_TABLE on TDEVC missing => system-level problem, not a
        # missing package. Don't pretend the package isn't there.
        Write-Host "RFC_ERROR: $msg"
    } else {
        Write-Host "RFC_ERROR: $msg"
    }
}
try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
exit 0
