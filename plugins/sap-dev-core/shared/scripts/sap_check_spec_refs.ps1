# =============================================================================
# sap_check_spec_refs.ps1  -  Spec-level (TABLE, FIELD) ref validator
#
# Pure file-I/O validator. Reads a request file listing (TABLE, FIELD, LOCATION)
# triples, validates each against a struct signature cache file, and appends
# findings to a result file in the check_result_process / check_result_ddic
# TSV format.
#
# Inputs (tokens replaced by caller):
#   %%REQUEST_FILE%%     TSV: <TABLE>\t<FIELD>\t<LOCATION>\t<CATEGORY>
#                        Example rows:
#                          MARA\tMATNR\tFILE_MAPPING_IN row 3\tCross-reference
#                          T001\tBUKRS\tVALIDATION rule 7\tCross-reference
#                          ZMMFIXEDVALS24D\tWAERK\tDDIC table CURR ref\tCross-reference
#                        FIELD may be empty when only existence of the TABLE
#                        needs to be checked.
#   %%STRUCT_SIG_FILE%%  Path to _struct_signatures.txt (from sap_rfc_lookup_struct.ps1)
#   %%RESULT_FILE%%      Path to check_result_*.txt (will be created with header
#                        if absent; rows appended otherwise — same TSV format
#                        the calling SKILL.md already uses).
#   %%STARTING_NO%%      First sequence number to use for "No" column
#                        (caller passes the count of existing rows + 1).
#
# Output: appends rows in the format
#   No\tCategory\tLocation\tDescription\tSeverity\tStatus
# matching check_result_process.txt / check_result_ddic.txt.
#
# Behavior:
#   table NOT_FOUND in cache         -> ERROR "Table <T> does not exist on target SAP"
#   table found, field empty         -> (skip — table-only check, no field to validate)
#   table found, field exists        -> (skip — no finding)
#   table found, field absent        -> ERROR "Field <F> does not exist on table <T>"
#   table UNAVAILABLE                -> WARNING "Cannot validate <T>.<F> — RFC unavailable"
#   table not in cache at all        -> (skip — unknown, caller should have run lookup first)
#
# Exit code: 0 always (additive checker; failures are emitted as findings,
# not as exit codes).
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

$REQUEST_FILE     = "%%REQUEST_FILE%%"
$STRUCT_SIG_FILE  = "%%STRUCT_SIG_FILE%%"
$RESULT_FILE      = "%%RESULT_FILE%%"
$STARTING_NO      = [int]"%%STARTING_NO%%"

if (-not (Test-Path $REQUEST_FILE)) {
    Write-Host "ERROR: Request file not found: $REQUEST_FILE"
    exit 0
}
if (-not (Test-Path $STRUCT_SIG_FILE) -or (Get-Item $STRUCT_SIG_FILE).Length -eq 0) {
    Write-Host "INFO: Struct cache file absent or empty — skipping spec-ref validation."
    exit 0
}

# ---- Load struct signature cache --------------------------------------------
$structFields      = @{}    # key = TABNAME, value = HashSet of FIELDNAME
$structNotFound    = @{}    # tabnames marked NOT_FOUND in cache
$structUnavailable = @{}    # tabnames marked UNAVAILABLE
foreach ($row in Get-Content -LiteralPath $STRUCT_SIG_FILE) {
    $cols = $row.Split("`t")
    if ($cols.Count -lt 3) { continue }
    $tab = $cols[0].Trim().ToUpper()
    $pos = $cols[1].Trim()
    $fld = $cols[2].Trim().ToUpper()
    if ($pos -eq "NOT_FOUND")    { $structNotFound[$tab] = $true; continue }
    if ($pos -eq "UNAVAILABLE")  { $structUnavailable[$tab] = $true; continue }
    if ($fld -eq "") { continue }
    if (-not $structFields.ContainsKey($tab)) {
        $structFields[$tab] = New-Object 'System.Collections.Generic.HashSet[string]'
    }
    [void]$structFields[$tab].Add($fld)
}
Write-Host ("INFO: Struct cache — " + $structFields.Count + " table(s) with field lists, " +
            $structNotFound.Count + " NOT_FOUND, " + $structUnavailable.Count + " UNAVAILABLE.")

# ---- Walk the request list --------------------------------------------------
$results = New-Object System.Collections.Generic.List[string]
$n = $STARTING_NO
$checks = 0
foreach ($row in Get-Content -LiteralPath $REQUEST_FILE) {
    $cols = $row.Split("`t")
    if ($cols.Count -lt 3) { continue }
    $tab = $cols[0].Trim().ToUpper()
    $fld = $cols[1].Trim().ToUpper()
    $loc = if ($cols.Count -ge 3) { $cols[2].Trim() } else { "" }
    $cat = if ($cols.Count -ge 4) { $cols[3].Trim() } else { "Cross-reference" }
    if ($tab -eq "") { continue }
    if ($tab.StartsWith("#")) { continue }   # comment lines

    $checks++

    if ($structNotFound.ContainsKey($tab)) {
        $results.Add("$n`t$cat`t$loc`tTable $tab does not exist on the target SAP system (per live RFC).`tError`tOpen")
        $n++
        continue
    }
    if ($structUnavailable.ContainsKey($tab)) {
        $results.Add("$n`t$cat`t$loc`tCannot validate $tab.$fld — RFC unavailable when the signature cache was populated.`tWarning`tOpen")
        $n++
        continue
    }
    if (-not $structFields.ContainsKey($tab)) {
        # Table not in cache — caller didn't request a lookup for it. Skip.
        continue
    }

    if ($fld -ne "" -and -not $structFields[$tab].Contains($fld)) {
        $results.Add("$n`t$cat`t$loc`tField $fld does not exist on table $tab (per live DDIF_FIELDINFO_GET).`tError`tOpen")
        $n++
    }
}

# ---- Append to result file (create with header if missing) ------------------
if ($results.Count -gt 0) {
    if (-not (Test-Path $RESULT_FILE)) {
        Set-Content -LiteralPath $RESULT_FILE -Value "No`tCategory`tLocation`tDescription`tSeverity`tStatus" -Encoding UTF8
    }
    Add-Content -LiteralPath $RESULT_FILE -Value $results -Encoding UTF8
    Write-Host ("INFO: Appended " + $results.Count + " finding(s) to " + $RESULT_FILE +
                "  (checked " + $checks + " ref(s))")
} else {
    Write-Host ("INFO: All " + $checks + " ref(s) validated cleanly; no findings appended.")
}
exit 0
