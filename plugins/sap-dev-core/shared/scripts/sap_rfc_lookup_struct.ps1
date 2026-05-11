# =============================================================================
# sap_rfc_lookup_struct.ps1  -  Fetch DDIC structure field lists with per-system cache
#
# Reads a request file (one DDIC structure / table / view / table-type name
# per line, e.g. BAPI_MARA), returns the live field list (FIELDNAME / ROLLNAME
# / DOMNAME / INTTYPE / LENG / DECIMALS / KEYFLAG) via DDIF_FIELDINFO_GET.
#
# Why this exists: sap_rfc_lookup_fm.ps1 returns FM parameter signatures
# (parameter name + STRUCTURE TYPE name). That tells the generator
# "CLIENTDATA is typed BAPI_MARA" but NOT what fields BAPI_MARA actually
# exposes on this release. AI training knowledge of BAPI internals is
# unreliable across S/4HANA releases — fields are added/removed/renamed.
# This script closes that gap: feed it the unique TABNAMEs from
# _fm_signatures.txt and it returns ground-truth field lists.
#
# Cache layout:
#   {CACHE_DIR}\<SYSTEM_ID>\<TABNAME>.tsv     -- one file per structure
#                                            -- file mtime = last fetched
#
# TTL strategy:
#   DDIC structures change rarely (SAP-shipped structures only on release
#   upgrades, Z-namespace during dev). Single knob TTL_DAYS, default 30 for
#   SAP-standard, 1 for Z*/Y* — mirrors the FM cache TTL policy.
#   Negative cache (struct not found) -> TTL_STD_DAYS.
#
# Run with **32-bit PowerShell**:
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File ...
#
# Tokens replaced by caller:
#   %%SAP_SERVER%%   %%SAP_SYSNR%%   %%SAP_CLIENT%%
#   %%SAP_USER%%     %%SAP_PASSWORD%%   %%SAP_LANGUAGE%%
#   %%REQUEST_FILE%%   Path to input file (one TABNAME per line)
#   %%RESULT_FILE%%    Path to output TSV (concatenation of all structures)
#   %%CACHE_DIR%%      Cache root, e.g. C:\sap_dev_work\cache\struct_signatures
#   %%SYSTEM_ID%%      Cache partition key, e.g. "saphost.example.com_00_100"
#   %%TTL_STD_DAYS%%   TTL for SAP-standard structures (default "30")
#   %%TTL_Z_DAYS%%     TTL for Z*/Y* structures (default "1")
#   %%REFRESH_CACHE%%  "true" to force re-fetch all (ignore cache)
#   %%RFC_LIB_PS1%%    Absolute path to sap_rfc_lib.ps1
#
# Output TSV row format (one row per field):
#   TABNAME<TAB>POSITION<TAB>FIELDNAME<TAB>ROLLNAME<TAB>DOMNAME<TAB>INTTYPE<TAB>LENG<TAB>DECIMALS<TAB>KEYFLAG
#
# Plus a special row when the structure doesn't exist on the server:
#   TABNAME<TAB>NOT_FOUND<TAB>
#
# Caller (sap-gen-abap Step 1.5e) injects this script's path via
# %%RFC_LOOKUP_STRUCT_PS1%%, resolved as
# <SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lookup_struct.ps1
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

$REQUEST_FILE  = "%%REQUEST_FILE%%"
$RESULT_FILE   = "%%RESULT_FILE%%"
$CACHE_DIR     = "%%CACHE_DIR%%"
$SYSTEM_ID     = "%%SYSTEM_ID%%"
$TTL_STD_DAYS  = [int]"%%TTL_STD_DAYS%%"
$TTL_Z_DAYS    = [int]"%%TTL_Z_DAYS%%"
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
    Write-Host "INFO: No structure names to look up."
    exit 0
}
Write-Host ("INFO: Requested " + $requestedNames.Count + " structure(s).")

# ---- Resolve cache directory ------------------------------------------------
$cacheBase = Join-Path $CACHE_DIR $SYSTEM_ID
if (-not (Test-Path $cacheBase)) {
    New-Item -Path $cacheBase -ItemType Directory -Force | Out-Null
    Write-Host "INFO: Created cache dir: $cacheBase"
}

function Get-TtlDays($structName) {
    if ($structName.StartsWith("Z") -or $structName.StartsWith("Y")) { return $TTL_Z_DAYS }
    return $TTL_STD_DAYS
}

function Test-CacheHit($structName) {
    if ($REFRESH_CACHE) { return $false }
    $path = Join-Path $cacheBase ($structName + ".tsv")
    if (-not (Test-Path $path)) { return $false }
    $age  = (Get-Date) - (Get-Item $path).LastWriteTime
    $ttl  = Get-TtlDays $structName
    return ($age.TotalDays -lt $ttl)
}

# ---- Triage: cache hits vs. misses ------------------------------------------
$hits   = @()
$misses = @()
foreach ($s in $requestedNames) {
    if (Test-CacheHit $s) { $hits += $s } else { $misses += $s }
}
Write-Host ("INFO: Cache hits: " + $hits.Count + " / " + $requestedNames.Count)
Write-Host ("INFO: Cache misses (will fetch): " + $misses.Count)

# ---- Fetch missing structs via RFC ------------------------------------------
$missesUnreachable = @()
if ($misses.Count -gt 0) {
    . "%%RFC_LIB_PS1%%"
    $g_dest = Connect-SapRfc -Server   "%%SAP_SERVER%%" `
                             -Sysnr    "%%SAP_SYSNR%%" `
                             -Client   "%%SAP_CLIENT%%" `
                             -User     "%%SAP_USER%%" `
                             -Password "%%SAP_PASSWORD%%" `
                             -Language "%%SAP_LANGUAGE%%" `
                             -DestName "SAPDEV_STRUCTLOOKUP"
    if (-not $g_dest) {
        Write-Host "ERROR: RFC connect failed; cannot fetch missing structures."
        $missesUnreachable = $misses
        $misses = @()
    }

    function Get-FieldStr($t, $name) {
        try { return ([string]$t.GetString($name)).Trim() } catch { return "" }
    }

    foreach ($structName in $misses) {
        $structContent = New-Object System.Text.StringBuilder
        $foundAny = $false
        try {
            $fn = $g_dest.Repository.CreateFunction("DDIF_FIELDINFO_GET")
            $fn.SetValue("TABNAME",      $structName)
            $fn.SetValue("ALL_TYPES",    "X")     # include sub-structures expanded
            $fn.SetValue("GROUP_NAMES",  " ")
            $fn.SetValue("LANGU",        "%%SAP_LANGUAGE%%")
            $fn.Invoke($g_dest)

            $dfies = $fn.GetTable("DFIES_TAB")
            for ($r = 0; $r -lt $dfies.RowCount; $r++) {
                $dfies.CurrentIndex = $r
                $fieldname = Get-FieldStr $dfies "FIELDNAME"
                if ($fieldname -eq "") { continue }
                # Skip ".INCLUDE" structural markers — those have empty FIELDNAME or special INTTYPE
                $position  = Get-FieldStr $dfies "POSITION"
                $rollname  = Get-FieldStr $dfies "ROLLNAME"
                $domname   = Get-FieldStr $dfies "DOMNAME"
                $inttype   = Get-FieldStr $dfies "INTTYPE"
                $leng      = Get-FieldStr $dfies "LENG"
                $decimals  = Get-FieldStr $dfies "DECIMALS"
                $keyflag   = Get-FieldStr $dfies "KEYFLAG"
                if ($keyflag -eq "") { $keyflag = " " }
                [void]$structContent.AppendLine(
                    "$structName`t$position`t$fieldname`t$rollname`t$domname`t$inttype`t$leng`t$decimals`t$keyflag")
                $foundAny = $true
            }
        } catch {
            Write-Host ("WARN: DDIF_FIELDINFO_GET on " + $structName + " failed: " + $_.Exception.Message)
        }

        if (-not $foundAny) {
            [void]$structContent.AppendLine("$structName`tNOT_FOUND`t")
            Write-Host ("WARN: " + $structName + " has no fields (or doesn't exist).")
        }

        $cacheFile = Join-Path $cacheBase ($structName + ".tsv")
        Set-Content -LiteralPath $cacheFile -Value $structContent.ToString().TrimEnd() -Encoding UTF8
    }

    try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($g_rfcParams) | Out-Null } catch {}
}

# ---- Concatenate cache files into the result TSV ---------------------------
$out = New-Object System.Text.StringBuilder
foreach ($structName in $requestedNames) {
    if ($missesUnreachable -contains $structName) {
        [void]$out.AppendLine("$structName`tUNAVAILABLE`t")
        continue
    }
    $path = Join-Path $cacheBase ($structName + ".tsv")
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
