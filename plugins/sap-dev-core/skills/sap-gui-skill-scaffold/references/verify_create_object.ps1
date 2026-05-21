# =============================================================================
# verify_create_object.ps1
# -----------------------------------------------------------------------------
# Type-routing post-create verifier for the autonomous test/fix loop
# (sap-gui-skill-scaffold Step 5.5c). Answers one question for a create-mode
# test: did the object actually land ACTIVE in the SAP system?
#
# Routing:
#   DDIC types (TABLE / STRUCTURE / DATAELEMENT / DOMAIN / TABLETYPE / VIEW /
#               SEARCHHELP / LOCKOBJECT / TYPEGROUP)
#       -> delegate to the shared sap_se11_post_activate_verify.ps1 (DD0xL reads)
#   PROGRAM / REPORT          -> RFC_READ_TABLE on TRDIR (active program dir)
#   FM / FUNCTIONMODULE       -> RFC_READ_TABLE on TFDIR
#   CLASS / INTERFACE         -> RFC_READ_TABLE on SEOCLASS
#   (any of the above also probes DWINACTIV by OBJ_NAME for the inactive state)
#
# Exit codes / stdout last-line (same contract as sap_se11_post_activate_verify):
#   0  ACTIVE
#   1  ERROR: <message>      (RFC unreachable / unsupported type / no creds)
#   2  INACTIVE
#   3  MISSING
#
# Callers fail-closed on INACTIVE / MISSING, soft-warn on ERROR (defense in
# depth; the generated mode VBS's status-bar check is the primary signal).
#
# MUST run under 32-bit PowerShell (SAP NCo 3.1 lives in the 32-bit GAC):
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -File verify_create_object.ps1 ...
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ObjectType,
    [Parameter(Mandatory = $true)] [string] $ObjectName
)

$ErrorActionPreference = 'Stop'

$type = $ObjectType.ToUpperInvariant()
$name = $ObjectName.ToUpperInvariant()

$sharedDir = (Resolve-Path -Path (Join-Path $PSScriptRoot '..\..\..\shared\scripts') -ErrorAction SilentlyContinue).Path
if (-not $sharedDir) {
    Write-Host "ERROR: could not resolve shared scripts dir from $PSScriptRoot"
    exit 1
}

# --- DDIC types: delegate to the existing post-activate verifier --------------
$ddicTypes = @('TABLE','STRUCTURE','DATAELEMENT','DOMAIN','TABLETYPE','VIEW','SEARCHHELP','LOCKOBJECT','TYPEGROUP')
if ($ddicTypes -contains $type) {
    $verifier = Join-Path $sharedDir 'sap_se11_post_activate_verify.ps1'
    if (-not (Test-Path $verifier)) {
        Write-Host "ERROR: DDIC verifier not found at $verifier"
        exit 1
    }
    & $verifier -ObjectType $type -ObjectName $name
    exit $LASTEXITCODE
}

# --- Non-DDIC types: RFC against the active catalog + DWINACTIV ----------------
$catalog = switch ($type) {
    'PROGRAM'        { @{ Tab = 'TRDIR';    Key = 'NAME'     } }
    'REPORT'         { @{ Tab = 'TRDIR';    Key = 'NAME'     } }
    'FM'             { @{ Tab = 'TFDIR';    Key = 'FUNCNAME' } }
    'FUNCTIONMODULE' { @{ Tab = 'TFDIR';    Key = 'FUNCNAME' } }
    'CLASS'          { @{ Tab = 'SEOCLASS'; Key = 'CLSNAME'  } }
    'INTERFACE'      { @{ Tab = 'SEOCLASS'; Key = 'CLSNAME'  } }
    default          { $null }
}
if (-not $catalog) {
    Write-Host "ERROR: unsupported OBJECT_TYPE '$type' (DDIC types delegate to sap_se11_post_activate_verify; non-DDIC supported: PROGRAM REPORT FM CLASS INTERFACE)."
    exit 1
}

. (Join-Path $sharedDir 'sap_rfc_lib.ps1')

# Connect-SapRfc auto-resolves credentials from the AI-session's pinned
# connection profile when params are omitted (Phase 4.3 fallback).
$dest = $null
try {
    $dest = Connect-SapRfc -DestName 'SCAF_VERIFY'
} catch {
    Write-Host "ERROR: RFC connect threw: $($_.Exception.Message)"
    exit 1
}
if (-not $dest) {
    Write-Host "ERROR: RFC connect failed (see INFO/ERROR above)."
    exit 1
}

try {
    # Active-catalog existence.
    $fnA = New-RfcReadTable -Destination $dest -Table $catalog.Tab -Delimiter '|'
    Add-RfcOption $fnA ("{0} = '{1}'" -f $catalog.Key, $name)
    Add-RfcField  $fnA $catalog.Key
    $fnA.Invoke($dest)
    $existsActive = ($fnA.GetTable('DATA').RowCount -gt 0)

    # Inactive workbench entry (best-effort; OBJ_NAME match catches the main object).
    $existsInactive = $false
    try {
        $fnI = New-RfcReadTable -Destination $dest -Table 'DWINACTIV' -Delimiter '|'
        Add-RfcOption $fnI ("OBJ_NAME = '{0}'" -f $name)
        Add-RfcField  $fnI 'OBJ_NAME'
        $fnI.Invoke($dest)
        $existsInactive = ($fnI.GetTable('DATA').RowCount -gt 0)
    } catch {}

    if     ($existsInactive) { Write-Host 'INACTIVE'; exit 2 }   # unactivated edit pending
    elseif ($existsActive)   { Write-Host 'ACTIVE';   exit 0 }
    else                     { Write-Host 'MISSING';  exit 3 }
}
catch {
    Write-Host "ERROR: RFC read failed: $($_.Exception.Message)"
    exit 1
}
finally {
    try { Disconnect-SapRfc | Out-Null } catch {}
}
