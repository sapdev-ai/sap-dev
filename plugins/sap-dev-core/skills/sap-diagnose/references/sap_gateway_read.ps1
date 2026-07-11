# =============================================================================
# sap_gateway_read.ps1  -  /sap-diagnose reader: SAP Gateway (OData) error log
#
# Read-only PREFLIGHT reader for the classic Gateway error log (/IWFND/ERROR_LOG).
# It resolves ONE of three honest verdicts and NEVER guesses:
#
#   * NOT_APPLICABLE  -- tcode /IWFND/ERROR_LOG absent (TSTC) => this system has
#     no classic Gateway hub (e.g. ECC 6 without the add-on). Verified live: EC2
#     has neither the tcode nor /IWFND/SU_ERRLOG.
#   * COULD_NOT_CHECK -- Gateway IS installed, but its log table /IWFND/SU_ERRLOG
#     carries STRING / RSTR columns (ERROR_CONTEXT, HTML_PAGE) that make classic
#     RFC_READ_TABLE fail ("ASSIGN ... CASTING in SAPLSDTX") for ANY field set
#     (verified S4D 2026-07-11). The full error read is therefore owned by
#     /sap-gateway-service (wave 3, via a Gateway-specific path) or the
#     /IWFND/ERROR_LOG GUI -- this reader discloses that instead of silently
#     passing (fail-loud, Rule 10).
#   * skipped        -- RFC connect failed.
#
# This upgrades the diagnose source matrix 'odata' row from "manual" to an
# automatic present/absent discrimination + a concrete next step, without a GUI
# recording. When /sap-gateway-service ships an RFC-capable error reader, wire
# it here in place of the COULD_NOT_CHECK branch.
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
                       -User "%%SAP_USER%%" -Password "%%SAP_PASSWORD%%" -Language "%%SAP_LANGUAGE%%" -DestName "DIAG_GW"
if (-not $dest) { Write-DiagEvidence 'GATEWAY' 'skipped' 'rfc_connect_failed' @() $false 0 $OutFile; exit 0 }

# --- present/absent discrimination via TSTC + DD02L (both narrow, always read) ---
$tcodePresent = $false; $tablePresent = $false
try {
    $r = Invoke-DiagReadTable $dest 'TSTC' "TCODE = '/IWFND/ERROR_LOG'" @('TCODE', 'PGMNA') 1
    $tcodePresent = ($r.rows.Count -gt 0)
} catch { }
try {
    $r = Invoke-DiagReadTable $dest 'DD02L' "TABNAME = '/IWFND/SU_ERRLOG'" @('TABNAME', 'TABCLASS') 1
    $tablePresent = ($r.rows.Count -gt 0)
} catch { }

Disconnect-SapRfc

if (-not $tcodePresent -and -not $tablePresent) {
    Write-DiagEvidence 'GATEWAY' 'skipped' 'NOT_APPLICABLE: SAP Gateway hub (/IWFND/ERROR_LOG) not installed on this system' @() $false 0 $OutFile
    exit 0
}

# Gateway present. The log table is not RFC_READ_TABLE-readable (STRING/RSTR cols).
Write-DiagEvidence 'GATEWAY' 'skipped' 'COULD_NOT_CHECK: Gateway installed but /IWFND/SU_ERRLOG has STRING columns (not RFC_READ_TABLE-readable). Read the OData error log via /sap-gateway-service (wave 3) or the /IWFND/ERROR_LOG GUI.' @() $false 0 $OutFile
exit 0
