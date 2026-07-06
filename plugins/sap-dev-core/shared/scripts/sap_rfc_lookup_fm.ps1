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
# Output TSV format: ONE header row (row 0), then one row per parameter
# (may be many per FM):
#   FM_NAME<TAB>SECTION<TAB>PARAM_NAME<TAB>OPTIONAL<TAB>TYPE_REF<TAB>TYPE_KIND
#     SECTION   = EXPORTING | IMPORTING | CHANGING | TABLES | EXCEPTIONS
#     OPTIONAL  = " " (mandatory) or "X" (optional)
#     TYPE_KIND = TAB | TDEF | TYP | "" (none / exception)
#
# *** SECTION is written in CALLER perspective (the keyword the calling ABAP
# *** uses in CALL FUNCTION), NOT the FM's own interface direction. So an FM
# *** IMPORT parameter (e.g. BAPI_MATERIAL_SAVEDATA HEADDATA) is emitted under
# *** EXPORTING, and an FM EXPORT parameter (e.g. RETURN) under IMPORTING --
# *** see the $sections table below. This is a load-bearing contract: the two
# *** consumers (scripts/lint-abap-contract.mjs and sap_check_fm.vbs) compare
# *** this SECTION column DIRECTLY against the caller's CALL FUNCTION keyword
# *** with NO direction flip. Do not "simplify" it to FM-interface direction
# *** or you reintroduce the 11x false CALLFUNC_WRONG_SECTION lint (2026-07-03).
#
# The header row exists so a consumer that skips row 0 (the linter does) parses
# every data row. Legacy caches predating this contract are auto-purged via the
# per-system format marker (.cache_format) so they can never poison the output.
#
# Plus a special row when the FM doesn't exist on the server:
#   FM_NAME<TAB>NOT_FOUND<TAB><TAB><TAB><TAB>
#
# The skill caller (sap-gen-abap, sap-check-abap, sap-fix-abap) injects the
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

# Canonical header row for the concatenated RESULT_FILE. Consumers (the CI
# lint scripts/lint-abap-contract.mjs, sap_check_fm.vbs) treat row 0 as the
# header and start parsing at row 1, so RESULT_FILE MUST lead with this line
# or the first FM's first parameter is silently dropped. Per-FM cache .tsv
# files stay headerless (one is concatenated per requested FM); the header is
# prepended once, here, to the assembled RESULT_FILE.
$FM_SIG_HEADER = "FM_NAME`tSECTION`tPARAM_NAME`tOPTIONAL`tTYPE_REF`tTYPE_KIND"

# Cache-format contract version. Bump when the per-FM .tsv shape or the SECTION
# perspective changes. A per-system marker file ({cacheBase}\.cache_format)
# records the version the cached files were written under; on mismatch/absence
# the stale files are purged and re-fetched, so a pre-contract (e.g. FM-interface
# direction) cache can never be concatenated as-is into a new build's output.
$CACHE_FORMAT_VERSION = 2

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
    [System.IO.File]::WriteAllText($RESULT_FILE, $FM_SIG_HEADER + "`r`n", $Utf8NoBom)
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

# ---- Cache-format guard -----------------------------------------------------
# Purge any cache written under a prior contract version (or an unmarked legacy
# cache) BEFORE triage, so a stale-direction / headerless .tsv can never be
# served. Unconditional purge is safe: the files regenerate on the next fetch,
# and stale-FORMAT data is poison we would rather drop than concatenate. When
# RFC is up the requested FMs are re-fetched below and the marker is re-stamped;
# when RFC is down the affected FMs fall through to UNAVAILABLE rows (which the
# lint treats as an honest skip) instead of flipped signatures.
$fmtMarkerPath = Join-Path $cacheBase ".cache_format"
$cacheFormatStale = $true
if (Test-Path $fmtMarkerPath) {
    try {
        $marker = ([string](Get-Content -Raw -LiteralPath $fmtMarkerPath)).Trim()
        if ($marker -eq [string]$CACHE_FORMAT_VERSION) { $cacheFormatStale = $false }
    } catch { }
}
if ($cacheFormatStale) {
    Write-Host "INFO: FM cache format marker missing/stale in $cacheBase -- purging prior-format cache (guarantees caller-perspective signatures)."
    try {
        Get-ChildItem -LiteralPath $cacheBase -Filter *.tsv -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Get-TtlDays($fmName) {
    if ($fmName.StartsWith("Z") -or $fmName.StartsWith("Y")) { return $TTL_Z_DAYS }
    return $TTL_STD_DAYS
}

function Test-CacheHit($fmName) {
    if ($REFRESH_CACHE -or $cacheFormatStale) { return $false }
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

    # CALLER-PERSPECTIVE MAPPING -- Sect is the keyword the CALLING ABAP writes,
    # which is the OPPOSITE of the FM's own interface tab:
    #   FM IMPORT_PARAMETER  (FM receives) -> caller writes it under EXPORTING
    #   FM EXPORT_PARAMETER  (FM returns)  -> caller reads  it under IMPORTING
    # e.g. BAPI_MATERIAL_SAVEDATA: HEADDATA (IMPORT_PARAMETER) -> EXPORTING,
    #      RETURN (EXPORT_PARAMETER) -> IMPORTING. Do NOT flip Sect<->Tab: the
    # linter + sap_check_fm.vbs compare Sect directly against the caller keyword.
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
        # Headerless by design: the single RESULT_FILE header is prepended once
        # during concatenation below, not per cache file.
        $cachePath = Join-Path $cacheBase ($fm + ".tsv")
        [System.IO.File]::WriteAllText($cachePath, $fmContent.ToString(), $Utf8NoBom)
    }

    # Stamp the cache-format marker now that the freshly-fetched files are in
    # the current contract version. Only when RFC actually connected ($g_dest)
    # -- an RFC-down run must leave a stale marker so the next healthy run heals.
    if ($g_dest) {
        try { [System.IO.File]::WriteAllText($fmtMarkerPath, [string]$CACHE_FORMAT_VERSION, $Utf8NoBom) } catch { }
    }

    Disconnect-SapRfc
}

# ---- Concatenate all requested FMs (cache hits + freshly fetched) into RESULT
# Lead with the canonical header row: consumers skip row 0, so without it the
# first FM's first parameter would be silently dropped by the lint.
$out = New-Object System.Text.StringBuilder
[void]$out.AppendLine($FM_SIG_HEADER)
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
