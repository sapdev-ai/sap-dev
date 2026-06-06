# =============================================================================
# sap_update_addon_detect.ps1  -  Detect best method to maintain an add-on table
#
# 1. SM30 -- does a maintenance view exist? (SAP GUI scripting via COM)
# 2. RFC  -- DD02L-MAINFLAG = 'X'?
# 3. RFC  -- does ZCMRUPDATE_ADDON_TABLE exist in TRDIR?
#
# Run with **32-bit PowerShell**.
#
# Tokens: %%SAP_SERVER%% %%SAP_SYSNR%% %%SAP_CLIENT%%
#         %%SAP_USER%%   %%SAP_PASSWORD%% %%SAP_LANGUAGE%%
#         %%TABLE_NAME%%
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

$TABLE_NAME    = "%%TABLE_NAME%%"

$bSM30OK    = $false
$sMainFlag  = ""
$bProgExist = $false

# --- 1. Attach to SAP GUI ---------------------------------------------------
# GetActiveObject can fail with CO_E_CLASSSTRING ("Invalid class string") on
# some Windows 11 + SAP GUI 760+ builds, even when SAP GUI is running and
# scripting is enabled. Cause: the SAPGUI ProgID is not always registered
# in the Running Object Table for the calling process bitness. We try the
# main and alternate ProgIDs before giving up. If all fail, exit with a
# distinct code (2) so the caller can skip detection and route directly to
# the universal program path (ZCMRUPDATE_ADDON_TABLE via VBS GetObject).
$session = $null
$progIds = @("SAPGUI", "SAPGUI.ScriptingCtrl.1", "SapGui.ScriptingCtrl.1")
$sapGui  = $null
$lastErr = ""
foreach ($progId in $progIds) {
    try {
        $sapGui = [System.Runtime.InteropServices.Marshal]::GetActiveObject($progId)
        Write-Host "INFO: Attached to SAP GUI via ProgID '$progId'."
        break
    } catch {
        $lastErr = $_.Exception.Message
    }
}
if (-not $sapGui) {
    Write-Host "ERROR: Cannot attach to SAP GUI via any known ProgID: $lastErr"
    Write-Host "       Tried: $($progIds -join ', ')"
    Write-Host "       Skip detection and call sap_update_addon_prog.vbs directly (universal path)."
    exit 2
}
try {
    $appl = $sapGui.GetScriptingEngine()
    foreach ($conn in $appl.Children) {
        foreach ($s in $conn.Children) { $session = $s; break }
        if ($session) { break }
    }
} catch { Write-Host "ERROR: Cannot get scripting engine: $($_.Exception.Message)"; exit 1 }
if (-not $session) { Write-Host "ERROR: No SAP GUI session found."; exit 1 }
Write-Host "INFO: Session acquired."

# --- 2. SM30 check ----------------------------------------------------------
Write-Host "INFO: Checking SM30 maintenance view for $TABLE_NAME..."
try {
    $session.findById("wnd[0]/tbar[0]/okcd").Text = "/nSM30"
    $session.findById("wnd[0]").sendVKey(0)
    Start-Sleep -Milliseconds 500
    $session.findById("wnd[0]/usr/ctxtVIEWNAME").Text = $TABLE_NAME
    try { $session.findById("wnd[0]/usr/btnSHOW_PUSH").Press() } catch { }
    Start-Sleep -Milliseconds 1000

    $sMsgType = ""; $sMsgText = ""
    try { $sMsgType = $session.findById("wnd[0]/sbar").MessageType } catch { }
    try { $sMsgText = $session.findById("wnd[0]/sbar").Text }        catch { }

    if ($sMsgType -eq "E" -or $sMsgType -eq "A") {
        Write-Host "INFO: SM30 check: NO maintenance view ($sMsgText)"
    } else {
        $sScreen = "$($session.Info.ScreenNumber)"
        if ($sScreen -ne "100" -and $sScreen -ne "1000") {
            Write-Host "INFO: SM30 check: Maintenance view EXISTS (screen $sScreen)"
            $bSM30OK = $true
        } elseif ($sMsgType -eq "" -and $sMsgText -eq "") {
            Write-Host "INFO: SM30 check: Unclear, no status bar message. Assuming NO."
        } else {
            Write-Host "INFO: SM30 check: Status=$sMsgType Msg=$sMsgText"
        }
    }
    $session.findById("wnd[0]/tbar[0]/okcd").Text = "/n"
    $session.findById("wnd[0]").sendVKey(0)
    Start-Sleep -Milliseconds 300
} catch {
    Write-Host "WARN: SM30 navigation failed: $($_.Exception.Message)"
}

# --- 3. RFC checks (DD02L MAINFLAG, TRDIR ZCMRUPDATE_ADDON_TABLE) ------------
. "%%RFC_LIB_PS1%%"
$rfcOk = $false
$g_dest = Connect-SapRfc -Server   "%%SAP_SERVER%%" `
                         -Sysnr    "%%SAP_SYSNR%%" `
                         -Client   "%%SAP_CLIENT%%" `
                         -User     "%%SAP_USER%%" `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SAPDEV_ADD"
if ($g_dest) { $rfcOk = $true } else { Write-Host "WARNING: RFC connect failed (continuing without RFC checks)." }

if ($rfcOk) {
    # 3a. DD02L MAINFLAG
    try {
        $fn = $g_dest.Repository.CreateFunction("RFC_READ_TABLE")
        $fn.SetValue("QUERY_TABLE", "DD02L")
        $fn.SetValue("DELIMITER",   "|")
        $fn.SetValue("ROWCOUNT",    1)
        $opts = $fn.GetTable("OPTIONS"); $opts.Append() | Out-Null
        $opts.SetValue("TEXT", "TABNAME = '" + $TABLE_NAME.ToUpper() + "' AND AS4LOCAL = 'A'")
        $flds = $fn.GetTable("FIELDS"); $flds.Append() | Out-Null; $flds.SetValue("FIELDNAME", "MAINFLAG")
        $fn.Invoke($g_dest)
        $d = $fn.GetTable("DATA")
        if ($d.RowCount -gt 0) { $d.CurrentIndex = 0; $sMainFlag = $d.GetString("WA").Trim() }
    } catch { Write-Host "WARN: DD02L read failed: $($_.Exception.Message)" }
    Write-Host "INFO: DD02L-MAINFLAG = '$sMainFlag'"

    # 3b. TRDIR ZCMRUPDATE_ADDON_TABLE
    try {
        $fn2 = $g_dest.Repository.CreateFunction("RFC_READ_TABLE")
        $fn2.SetValue("QUERY_TABLE", "TRDIR")
        $fn2.SetValue("DELIMITER",   "|")
        $fn2.SetValue("ROWCOUNT",    1)
        $o2 = $fn2.GetTable("OPTIONS"); $o2.Append() | Out-Null; $o2.SetValue("TEXT", "NAME = 'ZCMRUPDATE_ADDON_TABLE'")
        $f2 = $fn2.GetTable("FIELDS");  $f2.Append() | Out-Null; $f2.SetValue("FIELDNAME", "NAME")
        $fn2.Invoke($g_dest)
        if ($fn2.GetTable("DATA").RowCount -gt 0) { $bProgExist = $true }
    } catch { Write-Host "WARN: TRDIR read failed: $($_.Exception.Message)" }
    try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
}

# --- 4. Decide --------------------------------------------------------------
$sMethod = "NONE"
if     ($bSM30OK)            { $sMethod = "SM30" }
elseif ($sMainFlag -eq "X")  { $sMethod = "SE16" }
elseif ($bProgExist)         { $sMethod = "PROG" }

Write-Host "RESULT_SM30:$bSM30OK"
Write-Host "RESULT_MAINFLAG:$sMainFlag"
Write-Host "RESULT_PROG:$bProgExist"
Write-Host "RESULT_METHOD:$sMethod"
exit 0
