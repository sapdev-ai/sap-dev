# =============================================================================
# sap_rfc_connect.ps1  -  Standalone RFC connection probe (NCo 3.1)
#
# Thin wrapper around sap_rfc_lib.ps1 used by the sap-login skill to verify
# that RFC credentials work. Connects, pings, and exits with status. No
# additional RFC calls are made.
#
# Run with **32-bit PowerShell**:
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File <script>
#
# Tokens replaced at run time:
#   %%RFC_LIB_PS1%%              Absolute path to sap_rfc_lib.ps1
#   %%SAP_APPLICATION_SERVER%%   Application server hostname or IP
#   %%SAP_SYSTEM_NUMBER%%        2-digit system number
#   %%SAP_CLIENT%%               3-digit client
#   %%SAP_USER%%                 SAP username
#   %%SAP_PASSWORD%%             SAP password
#   %%SAP_LANGUAGE%%             Logon language
#
# Output (last line):
#   RESULT: SUCCESS  -> credentials accepted, ping OK
#   RESULT: FAILED   -> see preceding ERROR: line for diagnosis
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# Self-check: this script is a TEMPLATE. The percent-percent placeholders MUST
# be substituted before running. Detect un-substituted tokens and fail fast
# with a clear message - running unsubstituted produces an opaque PowerShell
# error. Skill authors who copy this template into a {WORK_TEMP} file with
# substitution don't trigger this.
#
# The token regex below matches our actual placeholder names only
# (RFC_LIB_PS1, SAP_APPLICATION_SERVER, SAP_SYSTEM_NUMBER, SAP_CLIENT,
# SAP_USER, SAP_PASSWORD, SAP_LANGUAGE) so it doesn't false-positive on
# example text in this comment.
$mySrc = Get-Content -Raw -LiteralPath $PSCommandPath
if ($mySrc -match '%%(RFC_LIB_PS1|SAP_APPLICATION_SERVER|SAP_SYSTEM_NUMBER|SAP_CLIENT|SAP_USER|SAP_PASSWORD|SAP_LANGUAGE)%%') {
    Write-Host "ERROR: This script is a TEMPLATE. Placeholders for RFC_LIB_PS1, SAP_USER etc."
    Write-Host "       must be substituted before execution. Do not run sap_rfc_connect.ps1"
    Write-Host "       directly from shared/scripts/. Instead invoke /sap-login, which copies"
    Write-Host "       this template to {WORK_TEMP} with all tokens replaced, then runs the copy."
    Write-Host "       See sap-login/SKILL.md for the substitution block."
    Write-Host "RESULT: FAILED"
    exit 2
}

. "%%RFC_LIB_PS1%%"
$g_dest = Connect-SapRfc -Server   "%%SAP_APPLICATION_SERVER%%" `
                         -Sysnr    "%%SAP_SYSTEM_NUMBER%%" `
                         -Client   "%%SAP_CLIENT%%" `
                         -User     "%%SAP_USER%%" `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SAPDEV_PROBE"
if (-not $g_dest) {
    Write-Host "RESULT: FAILED"
    exit 1
}

Disconnect-SapRfc
Write-Host "RESULT: SUCCESS"
exit 0
