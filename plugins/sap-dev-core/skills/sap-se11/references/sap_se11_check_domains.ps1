# =============================================================================
# sap_se11_check_domains.ps1  -  Check if domains exist in DD01L (NCo 3.1)
#
# Output: EXIST:<DOMNAME>  |  NOT_EXIST:<DOMNAME>
#
# Tokens: %%NAMES_FILE%%  %%SAP_SERVER%%  %%SAP_SYSNR%%  %%SAP_CLIENT%%
#         %%SAP_USER%%    %%SAP_PASSWORD%%  %%SAP_LANGUAGE%%
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$NAMES_FILE    = "%%NAMES_FILE%%"

if (-not (Test-Path $NAMES_FILE)) { Write-Host "ERROR: Names file not found: $NAMES_FILE"; exit 1 }

$dict = New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($line in Get-Content -LiteralPath $NAMES_FILE) {
    $n = $line.Trim()
    if ($n -ne "" -and -not $dict.ContainsKey($n)) { $dict[$n] = $false }
}
if ($dict.Count -eq 0) { Write-Host "ERROR: No domain names found."; exit 1 }
Write-Host ("INFO: Checking " + $dict.Count + " domain name(s)...")

. "%%RFC_LIB_PS1%%"
$g_dest = Connect-SapRfc -Server   "%%SAP_SERVER%%" `
                         -Sysnr    "%%SAP_SYSNR%%" `
                         -Client   "%%SAP_CLIENT%%" `
                         -User     "%%SAP_USER%%" `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SAPDEV_DOM"
if (-not $g_dest) { exit 1 }

try {
    $fn = $g_dest.Repository.CreateFunction("RFC_READ_TABLE")
    $fn.SetValue("QUERY_TABLE", "DD01L")
    $fn.SetValue("DELIMITER",   "|")
    $flds = $fn.GetTable("FIELDS")
    $flds.Append() | Out-Null; $flds.SetValue("FIELDNAME", "DOMNAME")
    $opts = $fn.GetTable("OPTIONS")
    $names = @($dict.Keys)
    for ($i = 0; $i -lt $names.Count; $i++) {
        $opts.Append() | Out-Null
        if ($i -eq 0) { $opts.SetValue("TEXT", "( DOMNAME = '" + $names[$i].ToUpper() + "'") }
        else          { $opts.SetValue("TEXT", "OR DOMNAME = '" + $names[$i].ToUpper() + "'") }
    }
    $opts.Append() | Out-Null; $opts.SetValue("TEXT", ") AND AS4LOCAL = 'A'")
    $fn.Invoke($g_dest)
    $data = $fn.GetTable("DATA")
    for ($r = 0; $r -lt $data.RowCount; $r++) {
        $data.CurrentIndex = $r
        $wa = $data.GetString("WA").Trim().Replace("|","")
        if ($wa -ne "" -and $dict.ContainsKey($wa)) { $dict[$wa] = $true }
    }
} catch {
    Write-Host "ERROR: RFC_READ_TABLE failed: $($_.Exception.Message)"
    try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
    exit 1
}

foreach ($k in $dict.Keys) {
    if ($dict[$k]) { Write-Host ("EXIST:" + $k) } else { Write-Host ("NOT_EXIST:" + $k) }
}
try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
Write-Host "INFO: Check complete."
exit 0
