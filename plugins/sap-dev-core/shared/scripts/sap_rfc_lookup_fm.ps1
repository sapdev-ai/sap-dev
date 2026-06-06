# =============================================================================
# sap_rfc_lookup_fm.ps1  -  Fetch FM signatures with per-system disk cache
#
# Reads a request file (one FM name per line), returns full parameter
# interface for each FM via RPY_FUNCTIONMODULE_READ_NEW. Caches results
# per SAP system to avoid redundant RFC roundtrips across runs.
#
# Cache layout:
#   {CACHE_DIR}\<SYSTEM_ID>\<FM_NAME>.tsv     -- one file per FM
#                                            -- file mtime = last fetched
#
# TTL strategy (file age vs. now):
#   FM name starts with Z* or Y*  ->  TTL_Z_DAYS    (default 1, customer code is volatile)
#   Otherwise (BAPI_*, RFC_*, etc.) ->  TTL_STD_DAYS  (default 30, SAP standard is stable)
#   Negative cache (FM not found) ->  TTL_STD_DAYS    (don't re-query missing FMs constantly)
#
# Run with **32-bit PowerShell**:
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File ...
#
# Tokens replaced by caller:
#   %%SAP_SERVER%%   %%SAP_SYSNR%%   %%SAP_CLIENT%%
#   %%SAP_USER%%     %%SAP_PASSWORD%%   %%SAP_LANGUAGE%%
#   %%REQUEST_FILE%%   Path to input file (one FM name per line)
#   %%RESULT_FILE%%    Path to output TSV (concatenation of all FMs)
#   %%CACHE_DIR%%      Cache root, e.g. C:\sap_dev_work\cache\fm_signatures
#   %%SYSTEM_ID%%      Cache partition key, e.g. "saphost.example.com_00_100"
#   %%TTL_STD_DAYS%%   TTL for SAP standard FMs (default "30")
#   %%TTL_Z_DAYS%%     TTL for Z*/Y* FMs (default "1")
#   %%REFRESH_CACHE%%  "true" to force re-fetch all (ignore cache)
#   %%RFC_LIB_PS1%%    Absolute path to sap_rfc_lib.ps1
#
# Output TSV row format (one row per parameter, may be many per FM):
#   FM_NAME<TAB>SECTION<TAB>PARAM_NAME<TAB>OPTIONAL<TAB>TYPE_REF<TAB>TYPE_KIND
#     SECTION   = EXPORTING | IMPORTING | CHANGING | TABLES | EXCEPTIONS
#     OPTIONAL  = " " (mandatory) or "X" (optional)
#     TYPE_KIND = TAB | TDEF | TYP | "" (none / exception)
#
# Plus a special row when the FM doesn't exist on the server:
#   FM_NAME<TAB>NOT_FOUND<TAB><TAB><TAB><TAB>
#
# The skill caller (sap-gen-abap, sap-check-fm, sap-fix-fm) injects the
# absolute path to this file via the %%RFC_LOOKUP_FM_PS1%% token, resolved
# as: <SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lookup_fm.ps1
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

# UTF-8 WITHOUT BOM. The default [System.Text.Encoding]::UTF8 emits a BOM
# (0xEF 0xBB 0xBF) which the downstream VBS reader (sap_check_fm.vbs) opens
# as plain ASCII via Scripting.FileSystem.OpenTextFile(... TristateFalse).
# Those three BOM bytes then get glued to the first column of the first
# row of every cache file -- turning "BAPI_MATERIAL_SAVEDATA" into a string
# that doesn't match fmIdxMap and silently dropping the first parameter
# (typically HEADDATA on BAPI_*_SAVEDATA family). Bug surfaced 2026-05-11
# during MaterialUpload_JA build.
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# ---- Inputs -----------------------------------------------------------------
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
    Write-Host "INFO: No FM names to look up."
    exit 0
}
Write-Host ("INFO: Requested " + $requestedNames.Count + " FM(s).")

# ---- Resolve cache directory ------------------------------------------------
$cacheBase = Join-Path $CACHE_DIR $SYSTEM_ID
if (-not (Test-Path $cacheBase)) {
    New-Item -Path $cacheBase -ItemType Directory -Force | Out-Null
    Write-Host "INFO: Created cache dir: $cacheBase"
}

function Get-TtlDays($fmName) {
    if ($fmName.StartsWith("Z") -or $fmName.StartsWith("Y")) { return $TTL_Z_DAYS }
    return $TTL_STD_DAYS
}

function Test-CacheHit($fmName) {
    if ($REFRESH_CACHE) { return $false }
    $path = Join-Path $cacheBase ($fmName + ".tsv")
    if (-not (Test-Path $path)) { return $false }
    $age  = (Get-Date) - (Get-Item $path).LastWriteTime
    $ttl  = Get-TtlDays $fmName
    return ($age.TotalDays -lt $ttl)
}

# ---- Triage: cache hits vs. misses ------------------------------------------
$hits   = @()
$misses = @()
foreach ($fm in $requestedNames) {
    if (Test-CacheHit $fm) { $hits += $fm } else { $misses += $fm }
}
Write-Host ("INFO: Cache hits: " + $hits.Count + " / " + $requestedNames.Count)
Write-Host ("INFO: Cache misses (will fetch): " + $misses.Count)

# ---- Fetch missing FMs via RFC (only if there are misses) -------------------
if ($misses.Count -gt 0) {
    . "%%RFC_LIB_PS1%%"
    $g_dest = Connect-SapRfc -Server   "%%SAP_SERVER%%" `
                             -Sysnr    "%%SAP_SYSNR%%" `
                             -Client   "%%SAP_CLIENT%%" `
                             -User     "%%SAP_USER%%" `
                             -Password "%%SAP_PASSWORD%%" `
                             -Language "%%SAP_LANGUAGE%%" `
                             -DestName "SAPDEV_FMLOOKUP"
    if (-not $g_dest) {
        Write-Host "ERROR: RFC connect failed; cannot fetch missing FMs."
        # Still write whatever we have from the cache so the caller doesn't break.
        $missesUnreachable = $misses
        $misses = @()
    } else {
        $missesUnreachable = @()
    }

    $sections = @(
        @{ Sect = "EXPORTING";  Tab = "IMPORT_PARAMETER";   IsExc = $false },
        @{ Sect = "IMPORTING";  Tab = "EXPORT_PARAMETER";   IsExc = $false },
        @{ Sect = "CHANGING";   Tab = "CHANGING_PARAMETER"; IsExc = $false },
        @{ Sect = "TABLES";     Tab = "TABLES_PARAMETER";   IsExc = $false },
        @{ Sect = "EXCEPTIONS"; Tab = "EXCEPTION_LIST";     IsExc = $true  }
    )

    function Get-Field($t, $name) {
        try { return ([string]$t.GetString($name)).Trim().ToUpper() } catch { return "" }
    }

    foreach ($fm in $misses) {
        $fmContent = New-Object System.Text.StringBuilder
        $found     = $true
        try {
            $fn = $g_dest.Repository.CreateFunction("RPY_FUNCTIONMODULE_READ_NEW")
            $fn.SetValue("FUNCTIONNAME", $fm)
            $fn.Invoke($g_dest)
        } catch {
            Write-Host ("WARN: " + $fm + " not found or call failed: " + $_.Exception.Message)
            $found = $false
        }

        if ($found) {
            foreach ($s in $sections) {
                try { $tab = $fn.GetTable($s.Tab) } catch { continue }
                for ($r = 0; $r -lt $tab.RowCount; $r++) {
                    $tab.CurrentIndex = $r
                    if ($s.IsExc) {
                        $pnm = Get-Field $tab "EXCEPTION"
                        if ($pnm -ne "") {
                            [void]$fmContent.AppendLine("$fm`t$($s.Sect)`t$pnm`tX`t`t")
                        }
                    } else {
                        $pnm = Get-Field $tab "PARAMETER"
                        if ($pnm -eq "") { continue }
                        $popt = ""
                        try { $popt = ([string]$tab.GetString("OPTIONAL")).Trim() } catch { }
                        if ($popt -eq "") { $popt = " " }
                        $ptab  = Get-Field $tab "TABNAME"
                        $ptdef = Get-Field $tab "TYPEDEF"
                        $ptyp  = Get-Field $tab "TYP"
                        if     ($ptab)  { $typeRef = $ptab;  $typeKind = "TAB"  }
                        elseif ($ptdef) { $typeRef = $ptdef; $typeKind = "TDEF" }
                        elseif ($ptyp)  { $typeRef = $ptyp;  $typeKind = "TYP"  }
                        else            { $typeRef = "";     $typeKind = ""     }
                        [void]$fmContent.AppendLine("$fm`t$($s.Sect)`t$pnm`t$popt`t$typeRef`t$typeKind")
                    }
                }
            }
        } else {
            # Negative cache: record that the FM was looked up but not found,
            # so we don't pound RFC re-asking on every run.
            [void]$fmContent.AppendLine("$fm`tNOT_FOUND`t`t`t`t")
        }

        # Write per-FM cache file (atomic-ish: write then move).
        # No BOM -- see header note; downstream VBS reads as plain ASCII.
        $cachePath = Join-Path $cacheBase ($fm + ".tsv")
        [System.IO.File]::WriteAllText($cachePath, $fmContent.ToString(), $Utf8NoBom)
    }

    Disconnect-SapRfc
}

# ---- Concatenate all requested FMs (cache hits + freshly fetched) into RESULT
$out = New-Object System.Text.StringBuilder
$writtenFms = @()
$missingFms = @()
foreach ($fm in $requestedNames) {
    $cachePath = Join-Path $cacheBase ($fm + ".tsv")
    if (Test-Path $cachePath) {
        [void]$out.Append((Get-Content -Raw -LiteralPath $cachePath))
        $writtenFms += $fm
    } else {
        # Cache file missing (RFC was unavailable AND no prior cache) -- note it
        $missingFms += $fm
        [void]$out.AppendLine("$fm`tUNAVAILABLE`t`t`t`t")
    }
}

[System.IO.File]::WriteAllText($RESULT_FILE, $out.ToString(), $Utf8NoBom)

# ---- Summary ----------------------------------------------------------------
Write-Host ("INFO: Wrote " + $writtenFms.Count + " FM signature(s) to " + $RESULT_FILE)
if ($missingFms.Count -gt 0) {
    Write-Host ("WARN: " + $missingFms.Count + " FM(s) had no cache and could not be fetched: " + ($missingFms -join ", "))
}
Write-Host ("INFO: Cache dir: " + $cacheBase)
exit 0
