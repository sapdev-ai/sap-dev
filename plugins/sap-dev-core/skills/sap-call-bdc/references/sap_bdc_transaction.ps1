# =============================================================================
# sap_bdc_transaction.ps1  -  Execute BDC via ABAP4_CALL_TRANSACTION over NCo
#
# Reads SHDB recording file (tab-delimited fixed-width), builds BDCDATA,
# calls ABAP4_CALL_TRANSACTION, collects MESS_TAB messages, writes results.
#
# Tokens:
#   %%SAP_SERVER%% %%SAP_SYSNR%% %%SAP_CLIENT%%
#   %%SAP_USER%%   %%SAP_PASSWORD%% %%SAP_LANGUAGE%%
#   %%TCODE%%       Transaction code
#   %%BDC_FILE%%    Path to SHDB recording
#   %%DISMODE%%     A/E/N/P
#   %%UPDMODE%%     A/S/L
#   %%RESULT_FILE%% Path to write results
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$TCODE         = "%%TCODE%%"
$BDC_FILE      = "%%BDC_FILE%%"
$DISMODE       = "%%DISMODE%%"
$UPDMODE       = "%%UPDMODE%%"
$RESULT_FILE   = "%%RESULT_FILE%%"

$global:resultLines = @()
function Add-Line([string]$s) { $global:resultLines += $s }
function Finish([string]$status) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("STATUS:`t$status")
    [void]$sb.AppendLine("TCODE:`t$TCODE")
    [void]$sb.AppendLine("DISMODE:`t$DISMODE")
    [void]$sb.AppendLine("UPDMODE:`t$UPDMODE")
    [void]$sb.AppendLine("TIMESTAMP:`t$(Get-Date)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("TCODE`tDYNAME`tDYNUMB`tMSGTYP`tMSGSPRA`tMSGID`tMSGNR`tMSGV1`tMSGV2`tMSGV3`tMSGV4`tENV`tFLDNAME")
    foreach ($l in $global:resultLines) { if ($l -ne "") { [void]$sb.AppendLine($l) } }
    [System.IO.File]::WriteAllText($RESULT_FILE, $sb.ToString(), [System.Text.Encoding]::UTF8)
    Write-Host ("STATUS: " + $status)
}

. "%%RFC_LIB_PS1%%"
$g_dest = Connect-SapRfc -Server   "%%SAP_SERVER%%" `
                         -Sysnr    "%%SAP_SYSNR%%" `
                         -Client   "%%SAP_CLIENT%%" `
                         -User     "%%SAP_USER%%" `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SAPDEV_BDC"
if (-not $g_dest) { Finish "ERROR: RFC connection failed."; exit 1 }

if (-not (Test-Path $BDC_FILE)) { Finish "ERROR: BDC file not found: $BDC_FILE"; exit 1 }

# Parse SHDB recording
$bdcRows = @()
foreach ($line in Get-Content -LiteralPath $BDC_FILE) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line.TrimStart().StartsWith("#")) { continue }
    $arr = $line.Split("`t")
    if ($arr.Length -lt 3) { continue }
    $col2 = $arr[2].Trim()
    if ($col2 -eq "X") {
        $bdcRows += [pscustomobject]@{ Kind = "S"; Program = $arr[0].Trim(); Dynpro = $arr[1].Trim(); Fnam = ""; Fval = "" }
    } elseif ($col2 -ne "T" -and $arr.Length -ge 4) {
        $fnam = $arr[3].Trim()
        if ($fnam -ne "") {
            $fval = if ($arr.Length -ge 5) { $arr[4].Trim() } else { "" }
            $bdcRows += [pscustomobject]@{ Kind = "F"; Program = ""; Dynpro = ""; Fnam = $fnam; Fval = $fval }
        }
    }
}
if ($bdcRows.Count -eq 0) { Finish "ERROR: No valid BDC records found in: $BDC_FILE"; exit 1 }
Write-Host ("INFO: Parsed " + $bdcRows.Count + " BDC rows from $BDC_FILE")

# Guard: refuse to post BDC data that still carries unsubstituted %%TOKENS%%
# (e.g. bdc_recording_SE21.txt ships %%PACKAGE%% / %%DESCRIPTION%% /
# %%TRANSPORT%% placeholders). Running it raw would type the literal token
# text into SAP fields. Substitute into a {RUN_TEMP} copy first (SKILL.md
# Step 2.5); this guard is the backstop.
$tokenRows = @($bdcRows | Where-Object { $_.Program.Contains("%%") -or $_.Fnam.Contains("%%") -or $_.Fval.Contains("%%") })
if ($tokenRows.Count -gt 0) {
    foreach ($t in $tokenRows) { Write-Host ("TOKEN: " + $t.Fnam + " = " + $t.Fval) }
    Finish "ERROR: unsubstituted %%tokens%% in BDC data ($($tokenRows.Count) row(s)) - substitute them into a {RUN_TEMP} copy before running (SKILL.md Step 2.5)."
    exit 1
}

try {
    $fn = $g_dest.Repository.CreateFunction("ABAP4_CALL_TRANSACTION")
    $fn.SetValue("TCODE",       $TCODE)
    $fn.SetValue("SKIP_SCREEN", " ")
    $fn.SetValue("MODE_VAL",    $DISMODE)
    $fn.SetValue("UPDATE_VAL",  $UPDMODE)
    $bdcTbl = $fn.GetTable("USING_TAB")
    foreach ($r in $bdcRows) {
        $bdcTbl.Append() | Out-Null
        if ($r.Kind -eq "S") {
            $bdcTbl.SetValue("PROGRAM",  $r.Program)
            $bdcTbl.SetValue("DYNPRO",   $r.Dynpro)
            $bdcTbl.SetValue("DYNBEGIN", "X")
        } else {
            $bdcTbl.SetValue("FNAM", $r.Fnam)
            $bdcTbl.SetValue("FVAL", $r.Fval)
        }
    }
    Write-Host "INFO: Calling transaction $TCODE (DISMODE=$DISMODE, UPDMODE=$UPDMODE)..."
    $fn.Invoke($g_dest)
} catch {
    Finish "ERROR: Transaction call failed: $($_.Exception.Message)"
    try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
    exit 1
}

# Collect messages and decide the verdict on MSGTYP codes ONLY
# (locale-independent -- never on translated message text):
#   any 'E' or 'A' row            -> ERROR + exit 1
#   no E/A but at least one 'W'   -> SUCCESS_WITH_WARNINGS
#   otherwise                     -> SUCCESS
$msgs = $fn.GetTable("MESS_TAB")
$msgCount = $msgs.RowCount
$errCount  = 0
$warnCount = 0
for ($i = 0; $i -lt $msgCount; $i++) {
    $msgs.CurrentIndex = $i
    $cols = @("TCODE","DYNAME","DYNUMB","MSGTYP","MSGSPRA","MSGID","MSGNR","MSGV1","MSGV2","MSGV3","MSGV4","ENV","FLDNAME")
    $vals = $cols | ForEach-Object { try { $msgs.GetString($_) } catch { "" } }
    Add-Line ($vals -join "`t")
    $typ = ("" + $vals[3]).Trim().ToUpperInvariant()
    if ($typ -eq "E" -or $typ -eq "A") {
        $errCount++
        $txt = @($vals[7], $vals[8], $vals[9], $vals[10] | Where-Object { ("" + $_).Trim() -ne "" }) -join " | "
        Write-Host ("MSG: TYPE=" + $typ + " ID=" + ("" + $vals[5]).Trim() + " NUMBER=" + ("" + $vals[6]).Trim() + " TEXT=" + $txt)
    } elseif ($typ -eq "W") {
        $warnCount++
    }
}

try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}

if ($errCount -gt 0) {
    Finish "ERROR: Transaction $TCODE returned $errCount E/A message(s) in MESS_TAB (of $msgCount total) - the posting failed."
    exit 1
} elseif ($warnCount -gt 0) {
    Finish "SUCCESS_WITH_WARNINGS: Transaction $TCODE executed. $msgCount message(s), $warnCount warning(s)."
    exit 0
} else {
    Finish "SUCCESS: Transaction $TCODE executed. $msgCount message(s)."
    exit 0
}
