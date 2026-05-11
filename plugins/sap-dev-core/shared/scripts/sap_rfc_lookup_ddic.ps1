# =============================================================================
# sap_rfc_lookup_ddic.ps1  -  Generic DDIC type / table lookup helper (NCo 3.1)
#
# Replaces SAP.Functions calls scattered inside legacy parser scripts. Reads a
# request file with one DDIC name per line and classifies each name into one
# of: STRUCT (or TABLE), TTYP (table type), DTEL (data element), DOMAIN,
# CLASS (or interface), or UNKNOWN.
#
# Run with **32-bit PowerShell**:
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File ...
#
# Tokens:
#   %%SAP_SERVER%%   %%SAP_SYSNR%%   %%SAP_CLIENT%%
#   %%SAP_USER%%     %%SAP_PASSWORD%%   %%SAP_LANGUAGE%%
#   %%REQUEST_FILE%% Path to input file (one TYPE name per line, e.g. EKPO, MARA)
#   %%RESULT_FILE%%  Path to output TSV
#
# Output TSV per line:
#   <NAME><TAB>STRUCT<TAB>FIELD1:DT:LEN:DEC|FIELD2:DT:LEN:DEC|...
#   <NAME><TAB>TTYP<TAB><LINE_TYPE>:<LINE_KIND>           where LINE_KIND is STRUCT|DTEL|UNKNOWN
#   <NAME><TAB>DTEL<TAB><DATATYPE>:<LENG>:<DECIMALS>
#   <NAME><TAB>DOMAIN<TAB><DATATYPE>:<LENG>:<DECIMALS>
#   <NAME><TAB>CLASS<TAB><CLSTYPE>                        CLSTYPE 0=class, 1=interface
#   <NAME><TAB>UNKNOWN<TAB>
#
# Lookup chain (stops at first hit):
#   1. DDIF_FIELDINFO_GET  -> STRUCT (also handles transparent / pool / cluster TABLE)
#   2. DD40L (TYPENAME)    -> TTYP   (table type; resolves ROWTYPE / ROWKIND)
#   3. DD04L (ROLLNAME)    -> DTEL   (data element)
#   4. DD01L (DOMNAME)     -> DOMAIN
#   5. SEOCLASS (CLSNAME)  -> CLASS  (global class) or INTERFACE (via CLSTYPE)
#   6. otherwise           -> UNKNOWN
#
# DDIF_FIELDINFO_GET raises NOT_FOUND for everything except structures and
# transparent / pool / cluster tables. Table types, data elements, domains,
# and classes all need their dedicated DDIC catalog table - DDIF won't fall
# through to them automatically.
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

$REQUEST_FILE  = "%%REQUEST_FILE%%"
$RESULT_FILE   = "%%RESULT_FILE%%"

if (-not (Test-Path $REQUEST_FILE)) { Write-Host "ERROR: Request file not found: $REQUEST_FILE"; exit 1 }
$names = @()
foreach ($line in Get-Content -LiteralPath $REQUEST_FILE) {
    $n = $line.Trim()
    if ($n -ne "") { $names += $n.ToUpper() }
}
if ($names.Count -eq 0) {
    Set-Content -LiteralPath $RESULT_FILE -Value "" -Encoding UTF8
    Write-Host "INFO: No names to look up."
    exit 0
}
$names = $names | Select-Object -Unique
Write-Host ("INFO: Looking up " + $names.Count + " name(s)...")

. "%%RFC_LIB_PS1%%"
$g_dest = Connect-SapRfc -Server   "%%SAP_SERVER%%" `
                         -Sysnr    "%%SAP_SYSNR%%" `
                         -Client   "%%SAP_CLIENT%%" `
                         -User     "%%SAP_USER%%" `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SAPDEV_DDIC"
if (-not $g_dest) {
    Set-Content -LiteralPath $RESULT_FILE -Value "" -Encoding UTF8
    exit 1
}

# --- Helper: read a single column tuple from a DDIC table by key ---
function Read-DdicRow {
    param(
        [Parameter(Mandatory=$true)] [string]$Table,
        [Parameter(Mandatory=$true)] [string]$Where,
        [Parameter(Mandatory=$true)] [string[]]$Fields
    )
    try {
        $rt = $g_dest.Repository.CreateFunction("RFC_READ_TABLE")
        $rt.SetValue("QUERY_TABLE", $Table)
        $rt.SetValue("DELIMITER",   "|")
        $rt.SetValue("ROWCOUNT",    1)
        $opts = $rt.GetTable("OPTIONS"); $opts.Append() | Out-Null
        $opts.SetValue("TEXT", $Where)
        $flds = $rt.GetTable("FIELDS")
        foreach ($f in $Fields) {
            $flds.Append() | Out-Null
            $flds.SetValue("FIELDNAME", $f)
        }
        $rt.Invoke($g_dest)
        $d = $rt.GetTable("DATA")
        if ($d.RowCount -le 0) { return $null }
        $d.CurrentIndex = 0
        $wa = $d.GetString("WA")
        $parts = $wa.Split('|')
        $out = @{}
        for ($i = 0; $i -lt $Fields.Count; $i++) {
            $val = if ($i -lt $parts.Length) { $parts[$i].Trim() } else { "" }
            $out[$Fields[$i]] = $val
        }
        return $out
    } catch {
        return $null
    }
}

$sb = New-Object System.Text.StringBuilder

foreach ($name in $names) {
    $resKind  = "UNKNOWN"
    $resData  = ""

    # ----- 1. DDIF_FIELDINFO_GET: structures + (transparent/pool/cluster) tables -----
    $isStruct = $false
    try {
        $fn = $g_dest.Repository.CreateFunction("DDIF_FIELDINFO_GET")
        $fn.SetValue("TABNAME", $name)
        $fn.SetValue("LANGU",   $g_sapLanguage)
        $fn.Invoke($g_dest)
        $tab = $fn.GetTable("DFIES_TAB")
        if ($tab.RowCount -gt 0) {
            $isStruct = $true
            $parts = @()
            for ($r = 0; $r -lt $tab.RowCount; $r++) {
                $tab.CurrentIndex = $r
                $fname  = ([string]$tab.GetString("FIELDNAME")).Trim().ToUpper()
                if ($fname -eq "" -or $fname -eq ".INCLUDE") { continue }
                $fdt    = ([string]$tab.GetString("DATATYPE")).Trim().ToUpper()
                $flen   = ([string]$tab.GetString("LENG")).Trim()
                $fdec   = ([string]$tab.GetString("DECIMALS")).Trim()
                $parts += "${fname}:${fdt}:${flen}:${fdec}"
            }
            $resKind = "STRUCT"
            $resData = ($parts -join "|")
        }
    } catch { } # NOT_FOUND for non-struct/table - try next branch

    # ----- 2. DD40L: table type -----
    if (-not $isStruct -and $resKind -eq "UNKNOWN") {
        # DD40L columns: TYPENAME, ROWTYPE (line type name), ROWKIND (E=DTEL, S=STRUCT/TABLE),
        #                ACCESSMODE (S/H/I/O), KEYDEF, AS4LOCAL.
        $row = Read-DdicRow -Table "DD40L" `
                            -Where "TYPENAME = '$name' AND AS4LOCAL = 'A'" `
                            -Fields @("ROWTYPE","ROWKIND","ACCESSMODE")
        if ($row) {
            $rowType = $row["ROWTYPE"]
            $rowKind = $row["ROWKIND"]
            # ROWKIND mapping per DD40L documentation: E=Data element, S=Structure, blank=built-in
            $lineKind = switch ($rowKind) {
                "E" { "DTEL" }
                "S" { "STRUCT" }
                default { "UNKNOWN" }
            }
            $resKind = "TTYP"
            $resData = "${rowType}:${lineKind}"
        }
    }

    # ----- 3. DD04L: data element -----
    if ($resKind -eq "UNKNOWN") {
        $row = Read-DdicRow -Table "DD04L" `
                            -Where "ROLLNAME = '$name' AND AS4LOCAL = 'A'" `
                            -Fields @("DATATYPE","LENG","DECIMALS")
        if ($row -and $row["DATATYPE"] -ne "") {
            $resKind = "DTEL"
            $resData = ("{0}:{1}:{2}" -f $row["DATATYPE"].ToUpper(), $row["LENG"], $row["DECIMALS"])
        }
    }

    # ----- 4. DD01L: domain -----
    if ($resKind -eq "UNKNOWN") {
        $row = Read-DdicRow -Table "DD01L" `
                            -Where "DOMNAME = '$name' AND AS4LOCAL = 'A'" `
                            -Fields @("DATATYPE","LENG","DECIMALS")
        if ($row -and $row["DATATYPE"] -ne "") {
            $resKind = "DOMAIN"
            $resData = ("{0}:{1}:{2}" -f $row["DATATYPE"].ToUpper(), $row["LENG"], $row["DECIMALS"])
        }
    }

    # ----- 5. SEOCLASS: global class or interface -----
    # SEOCLASS columns on S/4HANA 1909 (verified via DD03L probe):
    #   CLSNAME (key, CHAR30), CLSTYPE (NUMC1: '0'=class, '1'=interface),
    #   UUID (RAW16), REMOTE (CHAR1).
    # NOTE: SEOCLASS does NOT carry STATE / VERSION columns - those live in
    # SEOCLASSDF (version-specific definition). For type-classification we
    # only need existence + CLSTYPE.
    if ($resKind -eq "UNKNOWN") {
        $row = Read-DdicRow -Table "SEOCLASS" `
                            -Where "CLSNAME = '$name'" `
                            -Fields @("CLSTYPE")
        if ($row) {
            $resKind = "CLASS"
            $resData = $row["CLSTYPE"]
        }
    }

    [void]$sb.AppendLine("${name}`t${resKind}`t${resData}")
}

[System.IO.File]::WriteAllText($RESULT_FILE, $sb.ToString(), [System.Text.Encoding]::UTF8)
try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
Write-Host "INFO: Lookup written to $RESULT_FILE"
exit 0
