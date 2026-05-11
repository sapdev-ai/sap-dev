# =============================================================================
# sap_se91_check_messages.ps1  -  Check for duplicate message texts in T100
#
# Uses NCo 3.1 + RFC_READ_TABLE on T100 to find existing messages whose TEXT
# matches the requested texts. Outputs FOUND/NEW per requested message.
#
# Reads a tab-separated messages file:
#   000<TAB>Message text
#   001<TAB>Another message &1
#
# Tokens:
#   %%MSG_CLASS%%      Message class
#   %%MESSAGES_FILE%%  Path to messages file
#   %%SAP_SERVER%%  %%SAP_SYSNR%%  %%SAP_CLIENT%%
#   %%SAP_USER%%    %%SAP_PASSWORD%%  %%SAP_LANGUAGE%%
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$MSG_CLASS     = "%%MSG_CLASS%%"
$MESSAGES_FILE = "%%MESSAGES_FILE%%"

if (-not (Test-Path $MESSAGES_FILE)) { Write-Host "ERROR: Messages file not found: $MESSAGES_FILE"; exit 1 }

$reqList = @()
foreach ($line in Get-Content -LiteralPath $MESSAGES_FILE) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $tab = $line.IndexOf("`t")
    if ($tab -lt 0) { continue }
    $num = $line.Substring(0, $tab).Trim()
    # Strip non-digit BOM-ish chars
    while ($num.Length -gt 0 -and ($num[0] -lt '0' -or $num[0] -gt '9')) { $num = $num.Substring(1) }
    $txt = $line.Substring($tab + 1)
    $reqList += [pscustomobject]@{ Num = $num; Text = $txt }
}
if ($reqList.Count -eq 0) { Write-Host "ERROR: No messages found in file."; exit 1 }
Write-Host ("INFO: Checking " + $reqList.Count + " message text(s) for duplicates...")

. "%%RFC_LIB_PS1%%"
$g_dest = Connect-SapRfc -Server   "%%SAP_SERVER%%" `
                         -Sysnr    "%%SAP_SYSNR%%" `
                         -Client   "%%SAP_CLIENT%%" `
                         -User     "%%SAP_USER%%" `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SAPDEV_T100"
if (-not $g_dest) { exit 1 }

$dictExisting = @{}
try {
    $fn = $g_dest.Repository.CreateFunction("RFC_READ_TABLE")
    $fn.SetValue("QUERY_TABLE", "T100")
    $fn.SetValue("DELIMITER",   "|")
    $flds = $fn.GetTable("FIELDS")
    foreach ($f in @("MSGNR","TEXT")) { $flds.Append() | Out-Null; $flds.SetValue("FIELDNAME", $f) }
    $opts = $fn.GetTable("OPTIONS"); $opts.Append() | Out-Null
    $opts.SetValue("TEXT", "ARBGB = '" + $MSG_CLASS.ToUpper() + "' AND SPRSL = '" + $g_sapLanguage.ToUpper() + "'")
    $fn.Invoke($g_dest)
    $data = $fn.GetTable("DATA")
    for ($r = 0; $r -lt $data.RowCount; $r++) {
        $data.CurrentIndex = $r
        $wa = $data.GetString("WA")
        $p = $wa.Split('|')
        $msgnr = if ($p.Length -ge 1) { $p[0].Trim() } else { "" }
        $msgtx = if ($p.Length -ge 2) { $p[1].Trim() } else { "" }
        if ($msgtx -ne "" -and -not $dictExisting.ContainsKey($msgtx)) { $dictExisting[$msgtx] = $msgnr }
    }
    Write-Host ("INFO: Found " + $dictExisting.Count + " existing message(s) in " + $MSG_CLASS.ToUpper() + ".")
} catch {
    Write-Host "WARNING: RFC_READ_TABLE call failed: $($_.Exception.Message). Treating all messages as new."
}

foreach ($req in $reqList) {
    $t = $req.Text.Trim()
    if ($dictExisting.ContainsKey($t)) { Write-Host ("FOUND:" + $req.Num + ":" + $dictExisting[$t] + ":" + $t) }
    else                                { Write-Host ("NEW:"   + $req.Num + ":" + $t) }
}

try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
Write-Host "INFO: Check complete."
exit 0
