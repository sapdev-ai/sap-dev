# =============================================================================
# sap_transport_request.ps1  -  Check or Create SAP Transport Request via NCo
#
# Checks if a given transport request is modifiable. If not (released or
# not found), creates a new workbench transport request.
#
# TR_READ_REQUEST is NOT a remote-enabled FM, so the verify branch routes
# the call through Z_GENERIC_RFC_WRAPPER_TBL (deployed by /sap-dev-init).
# The wrapper FM is invoked exactly the way /sap-rfc-wrapper-fm does it:
# build a CT_PARAMS table with IV_TRKORR (IMPORTING) + CS_REQUEST (CHANGING),
# call the wrapper, then parse the returned asXML to extract H/TRSTATUS.
# Direct RFC invocation of TR_READ_REQUEST fails on NCo 3.1 with
# "cannot find STRUCTURE specified by TRWBO_REQUEST" because TRWBO_REQUEST
# contains deep substructures the .NET-side metadata cannot bind for a
# non-RFC-enabled function.
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
#                                resolved sap_dev_mode value here. Two
#                                symmetric guardrails refuse calls under
#                                mode=GUI:
#                                  * TR_INPUT non-empty (verify misroute)
#                                    -> use SKILL.md Step 1b GUI branch ->
#                                       /sap-se16n TABLE=E070
#                                  * TR_INPUT empty (create misroute)
#                                    -> use SKILL.md Step 1a Create Path GUI
#                                       branch -> /sap-se01
#                                Empty / unknown mode normalises to GUI
#                                (safe-by-default: refuse rather than
#                                silently use RFC).
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$TR_INPUT      = "%%TRANSPORT_REQUEST%%"
$SAP_DEV_MODE  = "%%SAP_DEV_MODE%%"

# Normalise sap_dev_mode up-front so both guardrails (verify + create) can
# consult it. Empty / unknown falls back to GUI (safe-by-default: refuse
# rather than silently use RFC).
$normalizedMode = ""
if ($null -ne $SAP_DEV_MODE) { $normalizedMode = $SAP_DEV_MODE.ToUpper().Trim() }
if ($normalizedMode -eq "" -or $normalizedMode -notin @("GUI","RFC","BDC")) { $normalizedMode = "GUI" }

$sTrkorr = $TR_INPUT.Trim()

# Guardrail #1 — VERIFY under GUI mode. The /sap-transport-request SKILL.md
# Step 1b GUI branch should route verification through `/sap-se16n` on
# table `E070` (a pure GUI read). Reaching this PS1 with a TR candidate AND
# mode=GUI means the SKILL.md dispatch was skipped — refuse loudly so the
# operator sees the issue instead of silently falling through to the RFC
# verifier (which would work for users who happen to have NCo, but breaks
# for pure-GUI environments — exactly what GUI mode is supposed to support).
if ($sTrkorr -ne "" -and $normalizedMode -eq "GUI") {
    Write-Host "ERROR: TR verification via TR_READ_REQUEST (wrapper FM) refused under sap_dev_mode=GUI."
    Write-Host "       Expected dispatch: /sap-transport-request SKILL.md Step 1b -> GUI branch -> /sap-se16n TABLE=E070."
    Write-Host "       This script is reachable for verification only when sap_dev_mode is RFC or BDC."
    Write-Host "       Recovery: re-invoke /sap-transport-request so SKILL.md Step 1b runs (it dispatches"
    Write-Host "                /sap-se16n on E070), OR temporarily set sap_dev_mode to RFC if the GUI is unavailable."
    Write-Host "RESULT_STATUS: ERROR"
    exit 1
}

. "%%RFC_LIB_PS1%%"
$g_dest = Connect-SapRfc -Server   "%%SAP_APPLICATION_SERVER%%" `
                         -Sysnr    "%%SAP_SYSTEM_NUMBER%%" `
                         -Client   "%%SAP_CLIENT%%" `
                         -User     "%%SAP_USER%%" `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SAPDEV_TR"
if (-not $g_dest) { Write-Host "RESULT_STATUS: ERROR"; exit 1 }

# --- Helper: extract a leaf element value from CS_REQUEST asXML -------------
function Get-XmlLeafValue {
    param([string]$Xml, [string]$Element)
    # asXML for CS_REQUEST nests fields like <H><TRSTATUS>D</TRSTATUS>...</H>.
    # A single <H>...</H> block can match an element multiple times if
    # nested structures repeat the same name; for TR header fields the
    # H-level instance is the first one. Regex is sufficient — no XML
    # parser dependency, and CS_REQUEST never carries CDATA or attributes
    # on these leaf elements. Self-closing form <X/> is the asXML rendering
    # of an empty char element and resolves to "".
    $pattern = "<$Element>([^<]*)</$Element>|<$Element\s*/>"
    $m = [regex]::Match($Xml, $pattern)
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ""
}

# --- Helper: classify TR_READ_REQUEST output --------------------------------
# Returns: 'D' / 'L' / 'R' / 'O' / 'N' / '' (TR not found) / $null (error)
function Get-TrStatusViaWrapper {
    param($Dest, [string]$Trkorr)

    # asXML scalar payloads. Use a single line — the wrapper FM
    # concatenates chunks RESPECTING BLANKS, so any newline becomes part
    # of the payload and breaks CALL TRANSFORMATION id.
    $xmlTrkorr = '<?xml version="1.0" encoding="utf-16"?>' +
                 '<asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0">' +
                 '<asx:values><DATA>' + $Trkorr + '</DATA></asx:values></asx:abap>'
    $xmlFlagX  = '<?xml version="1.0" encoding="utf-16"?>' +
                 '<asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0">' +
                 '<asx:values><DATA>X</DATA></asx:values></asx:abap>'

    try {
        $fn = $Dest.Repository.CreateFunction("Z_GENERIC_RFC_WRAPPER_TBL")
        $fn.SetValue("IV_FUNCNAME", "TR_READ_REQUEST")
        $tbl = $fn.GetTable("CT_PARAMS")

        # Row 1: IV_TRKORR (IMPORTING, TRKORR)
        $tbl.Append() | Out-Null
        $tbl.SetValue("PNAME",     "IV_TRKORR")
        $tbl.SetValue("PSEQ",      1)
        $tbl.SetValue("PTYPE",     "I")
        $tbl.SetValue("PTYPENAME", "TRKORR")
        $tbl.SetValue("PVALUE",    $xmlTrkorr)

        # Row 2: IV_READ_E070 = 'X'  — without this flag, TR_READ_REQUEST
        # fills only CS_REQUEST-H-TRKORR and leaves the rest of H blank,
        # which we'd misread as "TR not found". With the flag, the FM
        # populates TRSTATUS / TRFUNCTION / AS4USER / AS4DATE / etc.
        # PTYPENAME = XFELD (standard CHAR1 flag data element) — the
        # wrapper does CREATE DATA lr_data TYPE (<ptypename>), which
        # needs a resolvable DDIC name; bare 'C' would fail (no length).
        $tbl.Append() | Out-Null
        $tbl.SetValue("PNAME",     "IV_READ_E070")
        $tbl.SetValue("PSEQ",      1)
        $tbl.SetValue("PTYPE",     "I")
        $tbl.SetValue("PTYPENAME", "XFELD")
        $tbl.SetValue("PVALUE",    $xmlFlagX)

        # Row 3: CS_REQUEST (CHANGING, TRWBO_REQUEST) — empty payload,
        # wrapper allocates a default-initialized structure for the FM to
        # populate, then serializes the result back as asXML.
        $tbl.Append() | Out-Null
        $tbl.SetValue("PNAME",     "CS_REQUEST")
        $tbl.SetValue("PSEQ",      1)
        $tbl.SetValue("PTYPE",     "C")
        $tbl.SetValue("PTYPENAME", "TRWBO_REQUEST")
    } catch {
        Write-Host "INFO: Wrapper FM setup failed: $($_.Exception.Message)"
        return $null
    }

    try {
        $fn.Invoke($Dest)
    } catch {
        # Z_GENERIC_RFC_WRAPPER_TBL raises DYNAMIC_CALL_FAILED if
        # TR_READ_REQUEST itself raises (e.g., TR doesn't exist on this
        # system). Treat that as "TR not found" — TRSTATUS="".
        $msg = $_.Exception.Message
        if ($msg -match "DYNAMIC_CALL_FAILED" -or
            $msg -match "FM_NOT_FOUND" -or
            $msg -match "DESERIALIZATION_FAILED" -or
            $msg -match "SERIALIZATION_FAILED") {
            Write-Host "INFO: Wrapper invocation failed (treating as TR-not-found): $msg"
            return ""
        }
        Write-Host "INFO: Wrapper invocation error: $msg"
        return $null
    }

    # Reassemble CS_REQUEST chunks from the returned CT_PARAMS.
    $tblOut = $fn.GetTable("CT_PARAMS")
    $accum = ""
    for ($i = 0; $i -lt $tblOut.RowCount; $i++) {
        $tblOut.CurrentIndex = $i
        $pname  = $tblOut.GetString("PNAME").Trim()
        $ptype  = $tblOut.GetString("PTYPE").Trim()
        $pvalue = $tblOut.GetString("PVALUE")
        if ($pname -eq "CS_REQUEST" -and $ptype -eq "C") {
            $accum += $pvalue
        }
    }
    if ($accum -eq "") {
        # Wrapper succeeded but returned no payload — the FM populated an
        # empty structure (TR doesn't exist) or the type couldn't be
        # resolved on the ABAP side (the wrapper emits a single
        # placeholder row in that case — surfaces as accum="").
        return ""
    }

    $sStatus = Get-XmlLeafValue -Xml $accum -Element "TRSTATUS"
    return $sStatus
}

# --- 2. Check existing TR if provided ---------------------------------------
# $sTrkorr already trimmed above (the verify-guardrail consumed it).
$bNeedCreate = $true

if ($sTrkorr -ne "") {
    Write-Host "INFO: Checking transport request $sTrkorr via Z_GENERIC_RFC_WRAPPER_TBL..."
    $sStatus = Get-TrStatusViaWrapper -Dest $g_dest -Trkorr $sTrkorr
    if ($null -eq $sStatus) {
        Write-Host "INFO: Could not verify TR $sTrkorr via wrapper. Will create a new transport request."
    } elseif ($sStatus -eq "") {
        Write-Host "INFO: TR $sTrkorr not found in system. Will create a new transport request."
    } else {
        Write-Host "INFO: TR $sTrkorr status = $sStatus"
        if ($sStatus -eq "D" -or $sStatus -eq "L") {
            # D = Modifiable. L = Modifiable + protected (still writeable
            # by owner). Treat both as usable for development work.
            Write-Host "RESULT_TR: $sTrkorr"
            Write-Host "RESULT_STATUS: EXISTING_MODIFIABLE"
            $bNeedCreate = $false
        } elseif ($sStatus -eq "R" -or $sStatus -eq "O" -or $sStatus -eq "N") {
            Write-Host "INFO: TR $sTrkorr is released/in-release ($sStatus). Will create a new one."
        } else {
            Write-Host "INFO: TR $sTrkorr has unrecognised status '$sStatus'. Will create a new one."
        }
    }
}

# --- 3. Create new TR if needed ---------------------------------------------
# Guardrail #2 — CREATE under GUI mode. The /sap-transport-request SKILL.md
# Step 1a Create Path GUI branch should route TR creation through
# /sap-se01. If the skill driver routes an empty TR_INPUT here while
# sap_dev_mode = GUI, that's a SKILL.md dispatch bug — refuse loudly so
# the operator sees the issue instead of silently getting an RFC-created
# TR with a different description format than /sap-se01 would produce.
# $normalizedMode was set up-front next to Guardrail #1.
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
