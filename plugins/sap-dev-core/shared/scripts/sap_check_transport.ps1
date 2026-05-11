# =============================================================================
# sap_check_transport.ps1  -  Validate transport request via RFC_READ_TABLE
#
# Queries E070 to verify the transport request:
#   - Exists (E070-TRKORR = transport number)
#   - Is a Workbench Request (E070-TRFUNCTION = 'K')
#   - Is Modifiable (E070-TRSTATUS = 'D')
#
# Uses SAP NCo 3.1 (requires 32-bit PowerShell:
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -File ...).
#
# Tokens replaced at run time:
#   %%TRANSPORT%%                Transport request number
#   %%SAP_APPLICATION_SERVER%%   SAP application server
#   %%SAP_SYSTEM_NUMBER%%        System number
#   %%SAP_CLIENT%%               Client number
#   %%SAP_USER%%                 SAP user
#   %%SAP_PASSWORD%%             SAP password
#   %%SAP_LANGUAGE%%             Logon language
#
# Output (last line):
#   VALID                          - transport is OK to use
#   INVALID:NOT_FOUND              - transport does not exist
#   INVALID:NOT_WORKBENCH:X        - TRFUNCTION is X, expected K
#   INVALID:NOT_MODIFIABLE:X       - TRSTATUS is X, expected D
#   ERROR:...                      - RFC call failure
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$SAP_TRANSPORT = "%%TRANSPORT%%"

Write-Host "INFO: Validating transport request: $SAP_TRANSPORT"

. "%%RFC_LIB_PS1%%"
$g_dest = Connect-SapRfc -Server   "%%SAP_APPLICATION_SERVER%%" `
                         -Sysnr    "%%SAP_SYSTEM_NUMBER%%" `
                         -Client   "%%SAP_CLIENT%%" `
                         -User     "%%SAP_USER%%" `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SAPDEV_CHKTR"
if (-not $g_dest) { exit 1 }

try {
    $fn = $g_dest.Repository.CreateFunction("RFC_READ_TABLE")
    $fn.SetValue("QUERY_TABLE", "E070")
    $fn.SetValue("DELIMITER",   "|")

    $fields = $fn.GetTable("FIELDS")
    foreach ($f in @("TRKORR","TRFUNCTION","TRSTATUS")) {
        $fields.Append() | Out-Null
        $fields.SetValue("FIELDNAME", $f)
    }

    $opts = $fn.GetTable("OPTIONS")
    $opts.Append() | Out-Null
    $opts.SetValue("TEXT", "TRKORR = '" + $SAP_TRANSPORT.ToUpper() + "'")

    $fn.Invoke($g_dest)

    $data = $fn.GetTable("DATA")
    if ($data.RowCount -eq 0) {
        Write-Host "INVALID:NOT_FOUND"
        exit 0
    }

    $data.CurrentIndex = 0
    $wa = $data.GetString("WA")
    Write-Host "INFO: Raw WA = $wa"
    $parts = $wa.Split('|')
    $sTrkorr     = if ($parts.Length -ge 1) { $parts[0].Trim() } else { "" }
    $sTrFunction = if ($parts.Length -ge 2) { $parts[1].Trim() } else { "" }
    $sTrStatus   = if ($parts.Length -ge 3) { $parts[2].Trim() } else { "" }
    Write-Host "INFO: TRKORR=$sTrkorr TRFUNCTION=$sTrFunction TRSTATUS=$sTrStatus"

    if ($sTrFunction -ne "K") { Write-Host ("INVALID:NOT_WORKBENCH:" + $sTrFunction); exit 0 }
    if ($sTrStatus   -ne "D") { Write-Host ("INVALID:NOT_MODIFIABLE:" + $sTrStatus); exit 0 }
    Write-Host "VALID"
}
catch {
    Write-Host "ERROR: RFC_READ_TABLE failed on E070: $($_.Exception.Message)"
    exit 1
}
finally {
    try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
}
