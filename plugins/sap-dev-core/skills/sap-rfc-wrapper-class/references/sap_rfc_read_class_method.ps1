# =============================================================================
# sap_rfc_read_class_method.ps1  -  Read ABAP class method interface via NCo
#
# Reads SEOSUBCODF (parameter type defs) and SEOSUBCO (subcomponent list)
# via RFC_READ_TABLE. SEOPARAM is a DDIC structure, not a transparent table —
# don't query it.
#
# Output (one line per parameter):
#   PARDECLTYPE|SCONAME|TYPNAME|KEYFLAG|PASSTYPE
#     PARDECLTYPE : 0=Importing 1=Exporting 2=Changing 3=Returning
#     KEYFLAG     : blank=mandatory  X=optional
#     PASSTYPE    : 0=by value  1=by reference  2=by ref with default
# Method type line:  MTDTYPE|<n>     (0=instance, 1=static, 2=event)
# Exceptions:        EXCEPT|<EXCNAME>
# Final line:        SUCCESS
#
# Tokens:
#   %%SAP_SERVER%% %%SAP_SYSNR%% %%SAP_CLIENT%%
#   %%SAP_USER%%   %%SAP_PASSWORD%% %%SAP_LANGUAGE%%
#   %%CLASS_NAME%% %%METHOD_NAME%%
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$CLS = "%%CLASS_NAME%%"
$MTH = "%%METHOD_NAME%%"

. "%%RFC_LIB_PS1%%"
$g_dest = Connect-SapRfc -Server   "%%SAP_SERVER%%" `
                         -Sysnr    "%%SAP_SYSNR%%" `
                         -Client   "%%SAP_CLIENT%%" `
                         -User     "%%SAP_USER%%" `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SAPDEV_CLS"
if (-not $g_dest) { exit 1 }

function Read-Tab {
    param([string]$Table, [string[]]$Fields, [string]$Where, [int]$RowCount = 0)
    $fn = $g_dest.Repository.CreateFunction("RFC_READ_TABLE")
    $fn.SetValue("QUERY_TABLE", $Table)
    $fn.SetValue("DELIMITER",   "|")
    if ($RowCount -gt 0) { $fn.SetValue("ROWCOUNT", $RowCount) }
    $tFlds = $fn.GetTable("FIELDS")
    foreach ($f in $Fields) { $tFlds.Append() | Out-Null; $tFlds.SetValue("FIELDNAME", $f) }
    $tOpts = $fn.GetTable("OPTIONS")
    # split WHERE into 72-char chunks at spaces
    $rest = $Where
    while ($rest.Length -gt 72) {
        $cut = $rest.LastIndexOf(' ', 71)
        if ($cut -lt 1) { $cut = 71 }
        $tOpts.Append() | Out-Null; $tOpts.SetValue("TEXT", $rest.Substring(0, $cut))
        $rest = $rest.Substring($cut).TrimStart()
    }
    if ($rest.Length -gt 0) { $tOpts.Append() | Out-Null; $tOpts.SetValue("TEXT", $rest) }
    $fn.Invoke($g_dest)
    return $fn.GetTable("DATA")
}

# Verify class exists
try {
    $d = Read-Tab "SEOCLASS" @("CLSNAME") "CLSNAME = '$CLS'" 1
    if ($d.RowCount -eq 0) { Write-Host "ERROR: Class $CLS not found in SEOCLASS"; exit 1 }
} catch { Write-Host "ERROR: RFC_READ_TABLE failed on SEOCLASS: $($_.Exception.Message)"; exit 1 }

# Method type
try {
    $d = Read-Tab "SEOCOMPODF" @("MTDDECLTYP") "CLSNAME = '$CLS' AND CMPNAME = '$MTH'"
    if ($d.RowCount -eq 0) {
        Write-Host "ERROR: Method $MTH not found in class $CLS (SEOCOMPODF). May be a source-based class — fall back to RTTI helper FM."
        exit 1
    }
    $d.CurrentIndex = 0
    $sMtdType = $d.GetString("WA").Trim()
    Write-Host "MTDTYPE|$sMtdType"
} catch { Write-Host "ERROR: SEOCOMPODF read failed: $($_.Exception.Message)"; exit 1 }

# Parameters
try {
    $d = Read-Tab "SEOSUBCODF" @("SCONAME","PARDECLTYP","PARPASSTYP","TYPTYPE","TYPE","TABLEOF","PAROPTIONL") "CLSNAME = '$CLS' AND CMPNAME = '$MTH'"
    if ($d.RowCount -eq 0) {
        Write-Host "NOTE: SEOSUBCODF returned 0 rows for $CLS/$MTH."
        Write-Host "      This usually means the class is source-based (inline editor)"
        Write-Host "      and parameter metadata is not stored in DDIC. Use an RTTI helper FM."
    }
    for ($i = 0; $i -lt $d.RowCount; $i++) {
        $d.CurrentIndex = $i
        $wa = $d.GetString("WA")
        $p = $wa.Split('|')
        if ($p.Length -ge 7) {
            $sco  = $p[0].Trim()
            $pdt  = $p[1].Trim()
            $ppt  = $p[2].Trim()
            $tpn  = $p[4].Trim()
            $opt  = $p[6].Trim()
            if ($sco -ne "" -and $tpn -ne "") {
                Write-Host "$pdt|$sco|$tpn|$opt|$ppt"
            }
        }
    }
} catch { Write-Host "ERROR: SEOSUBCODF read failed: $($_.Exception.Message)"; exit 1 }

# Exceptions
try {
    $d = Read-Tab "SEOSUBCO" @("SCONAME") "CLSNAME = '$CLS' AND CMPNAME = '$MTH' AND SCOTYPE = '01'"
    for ($i = 0; $i -lt $d.RowCount; $i++) {
        $d.CurrentIndex = $i
        $exc = $d.GetString("WA").Trim()
        if ($exc -ne "") { Write-Host "EXCEPT|$exc" }
    }
} catch {
    Write-Host "NOTE: Could not read SEOSUBCO ($($_.Exception.Message))"
}

try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
Write-Host "SUCCESS"
exit 0
