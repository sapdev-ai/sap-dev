# =============================================================================
# sap_se11_check_dataelements.ps1  -  Check if data elements exist in DD04L
#
# NCo 3.1 batch-check via RFC_READ_TABLE. Outputs EXIST:<name>:<DATATYPE>
# or NOT_EXIST:<name> per data element.
#
# Tokens:
#   %%NAMES_FILE%%   File with one DTEL name per line
#   %%SAP_SERVER%%  %%SAP_SYSNR%%  %%SAP_CLIENT%%
#   %%SAP_USER%%    %%SAP_PASSWORD%%  %%SAP_LANGUAGE%%
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$NAMES_FILE    = "%%NAMES_FILE%%"

if (-not (Test-Path $NAMES_FILE)) { Write-Host "ERROR: Names file not found: $NAMES_FILE"; exit 1 }

# Case-insensitive dictionary
$dict = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($line in Get-Content -LiteralPath $NAMES_FILE) {
    $n = $line.Trim()
    if ($n -ne "" -and -not $dict.ContainsKey($n)) { $dict[$n] = "" }
}
if ($dict.Count -eq 0) { Write-Host "ERROR: No data element names found."; exit 1 }
Write-Host ("INFO: Checking " + $dict.Count + " data element name(s)...")

. "%%RFC_LIB_PS1%%"
$g_dest = Connect-SapRfc -Server   "%%SAP_SERVER%%" `
                         -Sysnr    "%%SAP_SYSNR%%" `
                         -Client   "%%SAP_CLIENT%%" `
                         -User     "%%SAP_USER%%" `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SAPDEV_DTEL"
if (-not $g_dest) { exit 1 }

try {
    $fn = $g_dest.Repository.CreateFunction("RFC_READ_TABLE")
    $fn.SetValue("QUERY_TABLE", "DD04L")
    $fn.SetValue("DELIMITER",   "|")
    $flds = $fn.GetTable("FIELDS")
    foreach ($f in @("ROLLNAME","DATATYPE")) { $flds.Append() | Out-Null; $flds.SetValue("FIELDNAME", $f) }
    $opts = $fn.GetTable("OPTIONS")
    $names = @($dict.Keys)
    for ($i = 0; $i -lt $names.Count; $i++) {
        $opts.Append() | Out-Null
        if ($i -eq 0) { $opts.SetValue("TEXT", "( ROLLNAME = '" + $names[$i].ToUpper() + "'") }
        else          { $opts.SetValue("TEXT", "OR ROLLNAME = '" + $names[$i].ToUpper() + "'") }
    }
    $opts.Append() | Out-Null; $opts.SetValue("TEXT", ") AND AS4LOCAL = 'A'")
    $fn.Invoke($g_dest)
    $data = $fn.GetTable("DATA")
    for ($r = 0; $r -lt $data.RowCount; $r++) {
        $data.CurrentIndex = $r
        $wa = $data.GetString("WA").Trim()
        $p = $wa.Split('|')
        $rn = if ($p.Length -ge 1) { $p[0].Trim() } else { "" }
        $dt = if ($p.Length -ge 2) { $p[1].Trim() } else { "" }
        if ($rn -ne "" -and $dict.ContainsKey($rn)) { $dict[$rn] = $dt }
    }
} catch {
    Write-Host "ERROR: RFC_READ_TABLE failed: $($_.Exception.Message)"
    try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
    exit 1
}

foreach ($k in $dict.Keys) {
    if ($dict[$k] -ne "") { Write-Host ("EXIST:" + $k + ":" + $dict[$k]) }
    else                  { Write-Host ("NOT_EXIST:" + $k) }
}
try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
Write-Host "INFO: Check complete."
exit 0
