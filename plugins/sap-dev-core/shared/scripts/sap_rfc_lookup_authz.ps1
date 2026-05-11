# =============================================================================
# sap_rfc_lookup_authz.ps1  -  Fetch SU21 field lists per authorization object
#
# Reads a request file (one auth-object name per line, e.g. M_MATE_MAR), returns
# the live SU21 field list (FIELD names in POSITION order) for each object via
# RFC_READ_TABLE on AUTHX. Caches results per SAP system to avoid redundant
# RFC roundtrips across runs. Mirrors sap_rfc_lookup_fm.ps1 in shape.
#
# Cache layout:
#   {CACHE_DIR}\<SYSTEM_ID>\<OBJCT>.tsv      -- one file per auth object
#                                            -- file mtime = last fetched
#
# TTL strategy:
#   Auth-object field lists are very stable (rarely changed by basis once an
#   object is shipped). Single TTL knob: TTL_DAYS, default 90.
#   Negative cache (object not found / no fields) -> same TTL.
#
# Run with **32-bit PowerShell**:
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File ...
#
# Tokens replaced by caller:
#   %%SAP_SERVER%%   %%SAP_SYSNR%%   %%SAP_CLIENT%%
#   %%SAP_USER%%     %%SAP_PASSWORD%%   %%SAP_LANGUAGE%%
#   %%REQUEST_FILE%%   Path to input file (one OBJCT name per line)
#   %%RESULT_FILE%%    Path to output TSV (concatenation of all objects)
#   %%CACHE_DIR%%      Cache root, e.g. C:\sap_dev_work\cache\authz_signatures
#   %%SYSTEM_ID%%      Cache partition key, e.g. "saphost.example.com_00_100"
#   %%TTL_DAYS%%       TTL for cached entries (default "90")
#   %%REFRESH_CACHE%%  "true" to force re-fetch all (ignore cache)
#   %%RFC_LIB_PS1%%    Absolute path to sap_rfc_lib.ps1
#
# Output TSV row format (one row per field):
#   OBJCT<TAB>POSITION<TAB>FIELD
#
# Plus a special row when the object doesn't exist on the server:
#   OBJCT<TAB>NOT_FOUND<TAB>
#
# Source table: TOBJ (Authorization object header). Standard SAP,
# RFC_READ_TABLE-compatible. Keyed on OBJCT. The field list lives in 10
# horizontal columns FIEL1, FIEL2, ..., FIEL9, FIEL0 (yes - FIEL0 is the
# 10th slot, not the 1st - SAP's slot numbering for this table is 1..9
# then 0). Empty slots are blank. Per-slot width: CHAR(10).
#
# NOTE: prior versions queried AUTHX with fields OBJCT/POSITION/FIELD.
# On S/4HANA 1909 AUTHX has columns FIELDNAME / ROLLNAME / CHECKTABLE /
# EXIT_FB - the query raised FIELD_NOT_VALID and every requested object
# was silently written as NOT_FOUND. The correct table is TOBJ.
#
# Caller injects this script's path via %%RFC_LOOKUP_AUTHZ_PS1%%, resolved as
# <SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lookup_authz.ps1
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

$REQUEST_FILE  = "%%REQUEST_FILE%%"
$RESULT_FILE   = "%%RESULT_FILE%%"
$CACHE_DIR     = "%%CACHE_DIR%%"
$SYSTEM_ID     = "%%SYSTEM_ID%%"
$TTL_DAYS      = [int]"%%TTL_DAYS%%"
$REFRESH_CACHE = ("%%REFRESH_CACHE%%" -eq "true")

if (-not (Test-Path $REQUEST_FILE)) {
    Write-Host "ERROR: Request file not found: $REQUEST_FILE"
    exit 1
}

# ---- Parse the request file -------------------------------------------------
$requestedNames = @()
foreach ($line in Get-Content -LiteralPath $REQUEST_FILE) {
    $n = $line.Trim()
    if ($n -ne "" -and -not $n.StartsWith("#")) { $requestedNames += $n.ToUpper() }
}
$requestedNames = $requestedNames | Select-Object -Unique
if ($requestedNames.Count -eq 0) {
    Set-Content -LiteralPath $RESULT_FILE -Value "" -Encoding UTF8
    Write-Host "INFO: No auth-object names to look up."
    exit 0
}
Write-Host ("INFO: Requested " + $requestedNames.Count + " auth object(s).")

# ---- Resolve cache directory ------------------------------------------------
$cacheBase = Join-Path $CACHE_DIR $SYSTEM_ID
if (-not (Test-Path $cacheBase)) {
    New-Item -Path $cacheBase -ItemType Directory -Force | Out-Null
    Write-Host "INFO: Created cache dir: $cacheBase"
}

function Test-CacheHit($obj) {
    if ($REFRESH_CACHE) { return $false }
    $path = Join-Path $cacheBase ($obj + ".tsv")
    if (-not (Test-Path $path)) { return $false }
    $age  = (Get-Date) - (Get-Item $path).LastWriteTime
    return ($age.TotalDays -lt $TTL_DAYS)
}

# ---- Triage: cache hits vs. misses ------------------------------------------
$hits   = @()
$misses = @()
foreach ($o in $requestedNames) {
    if (Test-CacheHit $o) { $hits += $o } else { $misses += $o }
}
Write-Host ("INFO: Cache hits: " + $hits.Count + " / " + $requestedNames.Count)
Write-Host ("INFO: Cache misses (will fetch): " + $misses.Count)

# ---- Fetch missing objects via RFC ------------------------------------------
$missesUnreachable = @()
if ($misses.Count -gt 0) {
    . "%%RFC_LIB_PS1%%"
    $g_dest = Connect-SapRfc -Server   "%%SAP_SERVER%%" `
                             -Sysnr    "%%SAP_SYSNR%%" `
                             -Client   "%%SAP_CLIENT%%" `
                             -User     "%%SAP_USER%%" `
                             -Password "%%SAP_PASSWORD%%" `
                             -Language "%%SAP_LANGUAGE%%" `
                             -DestName "SAPDEV_AUTHZLOOKUP"
    if (-not $g_dest) {
        Write-Host "ERROR: RFC connect failed; cannot fetch missing auth objects."
        $missesUnreachable = $misses
        $misses = @()
    }

    # TOBJ field columns in the order SAP stores them. POSITION in the output
    # TSV is the 1-based slot index (1..10); the SAP column name for slot 10
    # is FIEL0, not FIEL10.
    $tobjFields = @("FIEL1","FIEL2","FIEL3","FIEL4","FIEL5","FIEL6","FIEL7","FIEL8","FIEL9","FIEL0")

    foreach ($obj in $misses) {
        $objContent = New-Object System.Text.StringBuilder
        $foundAny   = $false
        try {
            $fn = $g_dest.Repository.CreateFunction("RFC_READ_TABLE")
            $fn.SetValue("QUERY_TABLE", "TOBJ")
            $fn.SetValue("DELIMITER",   "|")

            # Add OPTIONS row: OBJCT = '<obj>'
            $opts = $fn.GetTable("OPTIONS")
            $opts.Append() | Out-Null
            $opts.CurrentIndex = $opts.RowCount - 1
            $opts.SetValue("TEXT", "OBJCT = '$obj'")

            # Add FIELDS rows: OBJCT, OCLSS, FIEL1..FIEL9, FIEL0
            $flds = $fn.GetTable("FIELDS")
            $allCols = @("OBJCT", "OCLSS") + $tobjFields
            foreach ($colName in $allCols) {
                $flds.Append() | Out-Null
                $flds.CurrentIndex = $flds.RowCount - 1
                $flds.SetValue("FIELDNAME", $colName)
            }

            $fn.Invoke($g_dest)

            $data = $fn.GetTable("DATA")
            if ($data.RowCount -gt 0) {
                $data.CurrentIndex = 0
                $wa = $data.GetString("WA")
                $parts = $wa.Split('|')
                # parts[0]=OBJCT, parts[1]=OCLSS, parts[2..11]=FIEL1..FIEL9,FIEL0
                if ($parts.Count -ge 3) {
                    $objctVal = $parts[0].Trim()
                    for ($slot = 0; $slot -lt $tobjFields.Count; $slot++) {
                        $idx = 2 + $slot
                        if ($idx -lt $parts.Count) {
                            $fieldName = $parts[$idx].Trim()
                            if ($fieldName -ne "") {
                                $position = ($slot + 1)
                                [void]$objContent.AppendLine("$objctVal`t$position`t$fieldName")
                                $foundAny = $true
                            }
                        }
                    }
                }
            }
        } catch {
            Write-Host ("WARN: RFC_READ_TABLE on TOBJ for " + $obj + " failed: " + $_.Exception.Message)
        }

        if (-not $foundAny) {
            [void]$objContent.AppendLine("$obj`tNOT_FOUND`t")
            Write-Host ("WARN: " + $obj + " has no fields in TOBJ (or doesn't exist).")
        }

        $cacheFile = Join-Path $cacheBase ($obj + ".tsv")
        Set-Content -LiteralPath $cacheFile -Value $objContent.ToString().TrimEnd() -Encoding UTF8
    }

    try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
}

# ---- Concatenate cache files into the result TSV ---------------------------
$out = New-Object System.Text.StringBuilder
foreach ($obj in $requestedNames) {
    if ($missesUnreachable -contains $obj) {
        [void]$out.AppendLine("$obj`tUNAVAILABLE`t")
        continue
    }
    $path = Join-Path $cacheBase ($obj + ".tsv")
    if (Test-Path $path) {
        $body = Get-Content -LiteralPath $path -Raw
        if ($body -ne $null -and $body.Trim() -ne "") {
            [void]$out.AppendLine($body.TrimEnd())
        }
    }
}
Set-Content -LiteralPath $RESULT_FILE -Value $out.ToString().TrimEnd() -Encoding UTF8
Write-Host ("INFO: Wrote signatures to " + $RESULT_FILE)
Write-Host ("INFO: Cache dir: " + $cacheBase)
exit 0
