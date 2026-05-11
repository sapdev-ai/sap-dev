# =============================================================================
# sap_transport_request.ps1  -  Check or Create SAP Transport Request via NCo
#
# Checks if a given transport request is modifiable. If not (released or
# not found), creates a new workbench transport request.
#
# Run with **32-bit PowerShell**:
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File ...
#
# Tokens replaced at run time:
#   %%SAP_APPLICATION_SERVER%%   Application server hostname or IP
#   %%SAP_SYSTEM_NUMBER%%        2-digit system number
#   %%SAP_CLIENT%%               3-digit client
#   %%SAP_USER%%                 SAP username
#   %%SAP_PASSWORD%%             SAP password
#   %%SAP_LANGUAGE%%             Logon language
#   %%TRANSPORT_REQUEST%%        Existing TR number to check (may be empty)
#   %%SAP_DEV_MODE%%             GUI / RFC / BDC. The skill must pass the
#                                resolved sap_dev_mode value here. Acts as a
#                                guardrail: when an empty TR_INPUT is paired
#                                with mode=GUI, this script REFUSES to create
#                                a TR via CTS_API_CREATE_CHANGE_REQUEST and
#                                exits with a clear "wrong path" error. Under
#                                GUI mode, TR creation must go through
#                                /sap-se01 — see SKILL.md Step 1a Create Path
#                                "GUI branch". Verify-only calls (TR_INPUT
#                                non-empty) are always allowed regardless of
#                                mode. Empty value falls back to GUI for
#                                safety (refuse rather than silently create).
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$TR_INPUT      = "%%TRANSPORT_REQUEST%%"
$SAP_DEV_MODE  = "%%SAP_DEV_MODE%%"

. "%%RFC_LIB_PS1%%"
$g_dest = Connect-SapRfc -Server   "%%SAP_APPLICATION_SERVER%%" `
                         -Sysnr    "%%SAP_SYSTEM_NUMBER%%" `
                         -Client   "%%SAP_CLIENT%%" `
                         -User     "%%SAP_USER%%" `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SAPDEV_TR"
if (-not $g_dest) { Write-Host "RESULT_STATUS: ERROR"; exit 1 }

# --- 2. Check existing TR if provided ---------------------------------------
$bNeedCreate = $true
$sTrkorr = $TR_INPUT.Trim()

if ($sTrkorr -ne "") {
    Write-Host "INFO: Checking transport request $sTrkorr..."
    try {
        $fnRead = $g_dest.Repository.CreateFunction("TR_READ_REQUEST")
        $fnRead.SetValue("IV_TRKORR", $sTrkorr)
        $fnRead.Invoke($g_dest)
        $headers = $fnRead.GetTable("ET_REQUEST_HEADER")
        if ($headers.RowCount -gt 0) {
            $headers.CurrentIndex = 0
            $sStatus = $headers.GetString("TRSTATUS").Trim()
            Write-Host "INFO: TR $sTrkorr status = $sStatus"
            if ($sStatus -eq "D") {
                Write-Host "RESULT_TR: $sTrkorr"
                Write-Host "RESULT_STATUS: EXISTING_MODIFIABLE"
                $bNeedCreate = $false
            } elseif ($sStatus -eq "R") {
                Write-Host "INFO: TR $sTrkorr is released. Will create a new one."
            } else {
                Write-Host "INFO: TR $sTrkorr has status '$sStatus'. Will create a new one."
            }
        } else {
            Write-Host "INFO: TR $sTrkorr not found or empty header. Will create a new one."
        }
    } catch {
        Write-Host "INFO: TR_READ_REQUEST exception: $($_.Exception.Message). Will create a new transport request."
    }
}

# --- 3. Create new TR if needed ---------------------------------------------
# Mode guardrail: under GUI mode, TR creation must go through /sap-se01, not
# this RFC creator. If the skill driver routes an empty TR_INPUT here while
# the user's sap_dev_mode is GUI, that's a SKILL.md dispatch bug — refuse
# loudly so the operator sees the issue instead of silently getting an
# RFC-created TR with a different description format than /sap-se01 would
# produce. Empty mode falls back to GUI (safe-by-default).
$normalizedMode = ""
if ($null -ne $SAP_DEV_MODE) { $normalizedMode = $SAP_DEV_MODE.ToUpper().Trim() }
if ($normalizedMode -eq "" -or $normalizedMode -notin @("GUI","RFC","BDC")) { $normalizedMode = "GUI" }
if ($bNeedCreate -and $normalizedMode -eq "GUI") {
    Write-Host "ERROR: TR creation via CTS_API_CREATE_CHANGE_REQUEST refused under sap_dev_mode=GUI."
    Write-Host "       Expected dispatch: /sap-transport-request SKILL.md Step 1a Create Path -> GUI branch -> /sap-se01."
    Write-Host "       This script is reachable only for (a) verifying an existing TR (TR_INPUT non-empty), or"
    Write-Host "       (b) creating a new TR under sap_dev_mode in {RFC, BDC}."
    Write-Host "       Recovery: invoke /sap-se01 directly, OR temporarily set sap_dev_mode to RFC if the GUI is unavailable."
    Write-Host "RESULT_STATUS: ERROR"
    exit 1
}

# CTS_API_CREATE_CHANGE_REQUEST has two parameter-name conventions:
#   * Modern (S/4HANA 1909+): DESCRIPTION + CATEGORY (W=Workbench, K=Customizing).
#     Verified empirically on S/4HANA 1909 (2026-05-10): the legacy names
#     REQUEST_TEXT / REQUEST_TYPE produce a "field unknown" error.
#   * Legacy: REQUEST_TEXT + REQUEST_TYPE (K=Workbench, W=Customizing).
# Try the modern names first, fall back to legacy on RfcInvalidParameterException.
if ($bNeedCreate) {
    Write-Host "INFO: Creating new workbench transport request (sap_dev_mode=$normalizedMode)..."
    $sNewTR = ""
    $sCreateError = ""

    foreach ($variant in @(
        @{ Desc = "DESCRIPTION";  Cat = "CATEGORY";     CatVal = "W" },
        @{ Desc = "REQUEST_TEXT"; Cat = "REQUEST_TYPE"; CatVal = "K" }
    )) {
        try {
            $fnCreate = $g_dest.Repository.CreateFunction("CTS_API_CREATE_CHANGE_REQUEST")
            $fnCreate.SetValue($variant.Desc, "Basic Tools for sap-dev AI TR")
            $fnCreate.SetValue($variant.Cat,  $variant.CatVal)
            $fnCreate.SetValue("CLIENT",      $g_sapClient)
            $fnCreate.SetValue("OWNER",       $g_sapUser)
            $fnCreate.Invoke($g_dest)
            $sNewTR = $fnCreate.GetString("REQUEST").Trim()
            if ($sNewTR -ne "") {
                Write-Host "INFO: TR created via $($variant.Desc)/$($variant.Cat) signature."
                break
            }
            $sCreateError = "CTS_API_CREATE_CHANGE_REQUEST returned empty request number with $($variant.Desc)/$($variant.Cat)."
        } catch {
            $sCreateError = "CTS_API_CREATE_CHANGE_REQUEST failed with $($variant.Desc)/$($variant.Cat): $($_.Exception.Message)"
            Write-Host "INFO: $sCreateError - trying next signature variant."
        }
    }

    if ($sNewTR -ne "") {
        Write-Host "RESULT_TR: $sNewTR"
        Write-Host "RESULT_STATUS: NEWLY_CREATED"
    } else {
        Write-Host "ERROR: $sCreateError"
        Write-Host "RESULT_STATUS: ERROR"
    }
}

try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
exit 0
