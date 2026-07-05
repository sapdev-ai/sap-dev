# =============================================================================
# sap_rfc_read_fm_params.ps1  -  Read FM parameter interface via NCo (RPY_FUNCTIONMODULE_READ_NEW)
#
# Output per line: PTYPE|PNAME|TYPESPEC|OPTIONAL
#   PTYPE     : I=Importing  E=Exporting  C=Changing  T=Tables
#   TYPESPEC  : "TYPE <name>", "LIKE <table-fld>", "TYP=<x>", or blank
#   OPTIONAL  : X=optional, blank=mandatory
#
# Tokens: %%SAP_SERVER%% %%SAP_SYSNR%% %%SAP_CLIENT%% %%SAP_USER%%
#         %%SAP_PASSWORD%% %%SAP_LANGUAGE%% %%FM_NAME%%
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$FM_NAME       = "%%FM_NAME%%"

. "%%RFC_LIB_PS1%%"
$g_dest = Connect-SapRfc -Server   "%%SAP_SERVER%%" `
                         -Sysnr    "%%SAP_SYSNR%%" `
                         -Client   "%%SAP_CLIENT%%" `
                         -User     "%%SAP_USER%%" `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SAPDEV_FMR"
if (-not $g_dest) { exit 1 }

try {
    $fn = $g_dest.Repository.CreateFunction("RPY_FUNCTIONMODULE_READ_NEW")
    $fn.SetValue("FUNCTIONNAME", $FM_NAME)
    $fn.Invoke($g_dest)
} catch {
    Write-Host "ERROR: RPY_FUNCTIONMODULE_READ_NEW failed for $FM_NAME -- function module may not exist: $($_.Exception.Message)"
    exit 1
}

# Defensive field reader -- RPY_FUNCTIONMODULE_READ_NEW row metadata varies
# across releases and FMs. Some rows do not expose OPTIONAL, TYPES, DBFIELD,
# DBSTRUCT, TABNAME, or TYPEDEF, and a bare GetString throws a hard NCo
# error ("Element X of container metadata unknown") that aborts the loop.
function Get-Field($t, $name) {
    try { return ([string]$t.GetString($name)).Trim() } catch { return "" }
}

function Get-Spec($t) {
    $types = Get-Field $t "TYPES"
    if (-not $types) { $types = Get-Field $t "TYPEDEF" }
    $tab   = Get-Field $t "TABNAME"
    $dbf   = Get-Field $t "DBFIELD"
    $typ   = Get-Field $t "TYP"
    if ($types)   { return "TYPE $types" }
    elseif ($tab) { return "TYPE $tab" }
    elseif ($dbf) { return "LIKE $dbf" }
    elseif ($typ) { return "TYP=$typ" }
    else { return "" }
}
function Get-SpecTab($t) {
    $types = Get-Field $t "TYPES"
    if (-not $types) { $types = Get-Field $t "TYPEDEF" }
    $tab   = Get-Field $t "TABNAME"
    $dbs   = Get-Field $t "DBSTRUCT"
    $typ   = Get-Field $t "TYP"
    if ($types)   { return "TYPE $types" }
    elseif ($tab) { return "TYPE $tab" }
    elseif ($dbs) { return "LIKE $dbs" }
    elseif ($typ) { return "TYP=$typ" }
    else { return "" }
}

function Emit($section, $tableName, $isTab) {
    try { $t = $fn.GetTable($tableName) } catch { return }
    for ($i = 0; $i -lt $t.RowCount; $i++) {
        $t.CurrentIndex = $i
        $pn  = Get-Field $t "PARAMETER"
        if ($pn -eq "") { continue }
        $opt = Get-Field $t "OPTIONAL"
        if ($isTab) { Write-Host ("$section|$pn|" + (Get-SpecTab $t) + "|$opt") }
        else        { Write-Host ("$section|$pn|" + (Get-Spec    $t) + "|$opt") }
    }
}
Emit "I" "IMPORT_PARAMETER"   $false
Emit "E" "EXPORT_PARAMETER"   $false
Emit "C" "CHANGING_PARAMETER" $false
Emit "T" "TABLES_PARAMETER"   $true

try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
Write-Host "SUCCESS"
exit 0
