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

# Map any SAP logon-language token (1-char SAP code, 2-char ISO, or the English
# word) to the T100 SPRSL 1-char key. T100 is keyed on the 1-char code, so the
# pre-fix filter `SPRSL = 'EN'` matched zero rows and every message reported NEW.
# Mirrors the 1-char<->ISO table in sap_connection_lib.ps1 /
# sap_syntax_check_lib.vbs; falls back to the first char for unmapped tokens.
function ConvertTo-Sap1CharLang {
    param([string]$Language)
    if ([string]::IsNullOrWhiteSpace($Language)) { return 'E' }
    $k = $Language.Trim().ToUpperInvariant()
    $map = @{
        'E'='E'; 'EN'='E'; 'ENGLISH'='E'
        'D'='D'; 'DE'='D'; 'GERMAN'='D'
        'F'='F'; 'FR'='F'; 'FRENCH'='F'
        'S'='S'; 'ES'='S'; 'SPANISH'='S'
        'I'='I'; 'IT'='I'; 'ITALIAN'='I'
        'P'='P'; 'PT'='P'; 'PORTUGUESE'='P'
        '1'='1'; 'ZH'='1'; 'CHINESE'='1'   # simplified
        'M'='M'; 'ZF'='M'                   # traditional
        'J'='J'; 'JA'='J'; 'JAPANESE'='J'
        '3'='3'; 'KO'='3'; 'KOREAN'='3'
        'R'='R'; 'RU'='R'; 'RUSSIAN'='R'
    }
    if ($map.ContainsKey($k)) { return $map[$k] }
    return $k.Substring(0, 1)
}

if (-not (Test-Path $MESSAGES_FILE)) { Write-Host "ERROR: Messages file not found: $MESSAGES_FILE"; exit 1 }

$reqList = @()
foreach ($line in Get-Content -LiteralPath $MESSAGES_FILE) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line.IndexOf("`t") -lt 0) { continue }
    # Accept BOTH 2-column (<num>\t<text>) and 3-column (<num>\t<type>\t<text>,
    # emitted by sap-docs-extract) formats. First col = number, LAST col = text.
    # The pre-fix code kept everything after the FIRST tab, so a 3-column line
    # yielded "<type>\t<text>" and never matched T100.TEXT -> every message NEW.
    $cols = $line.Split("`t")
    $num = $cols[0].Trim()
    # Strip non-digit BOM-ish chars
    while ($num.Length -gt 0 -and ($num[0] -lt '0' -or $num[0] -gt '9')) { $num = $num.Substring(1) }
    $txt = $cols[$cols.Length - 1]
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
    # T100 SPRSL is a 1-char SAP language key; map the logon language token.
    $t100Lang = ConvertTo-Sap1CharLang $g_sapLanguage
    $opts.SetValue("TEXT", "ARBGB = '" + $MSG_CLASS.ToUpper() + "' AND SPRSL = '" + $t100Lang + "'")
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
