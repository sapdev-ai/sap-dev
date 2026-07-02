# =============================================================================
# sap_rfc_wrapper_fm.ps1  -  Call Z_GENERIC_RFC_WRAPPER_TBL via NCo 3.1
#
# Reads parameters from a tab-delimited file, splits long PVALUE payloads
# into 1333-char chunks (CT_PARAMS row per chunk), invokes the wrapper,
# then reassembles output chunks per E/C/T parameter and writes one XML
# per output parameter to %%RUN_TEMP%%\out_<PNAME>.xml
#
# Params file (one line per parameter):
#   <name><TAB>I/E/C/T<TAB><DDIC type><TAB><inline asXML or blank>
#
# Tokens: %%SAP_SERVER%% %%SAP_SYSNR%% %%SAP_CLIENT%% %%SAP_USER%%
#         %%SAP_PASSWORD%% %%SAP_LANGUAGE%% %%TARGET_FM%%
#         %%PARAMS_FILE%% %%RUN_TEMP%%
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$CHUNK_LEN = 1333

$TARGET_FM     = "%%TARGET_FM%%"
$PARAMS_FILE   = "%%PARAMS_FILE%%"
$RUN_TEMP      = "%%RUN_TEMP%%"

if (-not (Test-Path $PARAMS_FILE)) { Write-Host "ERROR: Params file not found: $PARAMS_FILE"; exit 1 }

. "%%RFC_LIB_PS1%%"
$g_dest = Connect-SapRfc -Server   "%%SAP_SERVER%%" `
                         -Sysnr    "%%SAP_SYSNR%%" `
                         -Client   "%%SAP_CLIENT%%" `
                         -User     "%%SAP_USER%%" `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SAPDEV_WRAP"
if (-not $g_dest) { Write-Host "ERROR: SAP Logon failed (silent)."; exit 1 }

try {
    $fn = $g_dest.Repository.CreateFunction("Z_GENERIC_RFC_WRAPPER_TBL")
    $fn.SetValue("IV_FUNCNAME", $TARGET_FM)
    $tbl = $fn.GetTable("CT_PARAMS")
} catch {
    Write-Host "ERROR: CT_PARAMS table not exposed by Z_GENERIC_RFC_WRAPPER_TBL: $($_.Exception.Message)"
    try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
    exit 1
}

# --- Load params file and chunk into rows ----------------------------------
$rowNum = 0
$lines  = Get-Content -LiteralPath $PARAMS_FILE
foreach ($line in $lines) {
    if ([string]::IsNullOrEmpty($line)) { continue }
    if ($rowNum -eq 0 -and $line.Length -ge 5 -and $line.Substring(0,5).ToUpper() -eq "PNAME") { continue }
    $aRow = $line.Split("`t")
    if ($aRow.Length -lt 3) { continue }
    $pname     = $aRow[0].Trim()
    $ptype     = $aRow[1].Trim()
    $ptypename = $aRow[2].Trim()
    $payload   = if ($aRow.Length -ge 4) { $aRow[3] } else { "" }
    $payLen    = $payload.Length
    if ($payLen -eq 0) {
        $rowNum++
        $tbl.Append() | Out-Null
        $tbl.SetValue("PNAME",     $pname)
        $tbl.SetValue("PSEQ",      1)
        $tbl.SetValue("PTYPE",     $ptype)
        $tbl.SetValue("PTYPENAME", $ptypename)
    } else {
        $off = 0; $seq = 0
        while ($off -lt $payLen) {
            $seq++
            $len = [Math]::Min($CHUNK_LEN, $payLen - $off)
            $chunk = $payload.Substring($off, $len)
            $rowNum++
            $tbl.Append() | Out-Null
            $tbl.SetValue("PNAME",     $pname)
            $tbl.SetValue("PSEQ",      $seq)
            $tbl.SetValue("PTYPE",     $ptype)
            $tbl.SetValue("PTYPENAME", $ptypename)
            $tbl.SetValue("PVALUE",    $chunk)
            $off += $CHUNK_LEN
        }
    }
}
if ($rowNum -eq 0) { Write-Host "ERROR: No parameters loaded from params file"; exit 1 }

try {
    $fn.Invoke($g_dest)
} catch {
    Write-Host "ERROR: Z_GENERIC_RFC_WRAPPER_TBL call failed for $TARGET_FM"
    Write-Host "       Exception: $($_.Exception.Message)"
    try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
    exit 1
}

Write-Host "SUCCESS: Z_GENERIC_RFC_WRAPPER_TBL executed for $TARGET_FM"

# --- Reassemble output chunks per E/C/T parameter --------------------------
$tblOut = $fn.GetTable("CT_PARAMS")
$lastPName = ""
$accum = ""
$outCount = 0
for ($i = 0; $i -lt $tblOut.RowCount; $i++) {
    $tblOut.CurrentIndex = $i
    $pname  = $tblOut.GetString("PNAME").Trim()
    $ptype  = $tblOut.GetString("PTYPE").Trim()
    $pvalue = $tblOut.GetString("PVALUE")
    if ($ptype -in @("E","C","T")) {
        if ($lastPName -ne "" -and $pname -ne $lastPName) {
            $outPath = Join-Path $RUN_TEMP "out_$lastPName.xml"
            [System.IO.File]::WriteAllText($outPath, $accum, [System.Text.UnicodeEncoding]::new($false, $true))
            Write-Host "OUTPUT_FILE: $lastPName -> $outPath"
            $outCount++
            $accum = ""
        }
        $lastPName = $pname
        $accum    += $pvalue
    }
}
if ($lastPName -ne "") {
    $outPath = Join-Path $RUN_TEMP "out_$lastPName.xml"
    [System.IO.File]::WriteAllText($outPath, $accum, [System.Text.UnicodeEncoding]::new($false, $true))
    Write-Host "OUTPUT_FILE: $lastPName -> $outPath"
    $outCount++
}
if ($outCount -eq 0) { Write-Host "NOTE: No output parameters to report" }

try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
exit 0
