# =============================================================================
# sap_check_signatures.ps1  -  Post-parse ABAP validator using cached SAP signatures
#
# Validates two error classes that the parser-only sap_check_abap.vbs can't
# catch offline, by consulting the live-SAP signature caches that sap-gen-abap
# populates at Step 1.5e (_struct_signatures.txt) and 1.5b' (_authz_signatures.txt):
#
#   A) STRUCT field references -- every `<var>-<field>` in the source where
#      <var> is declared `TYPE <some_struct>` is checked against the cached
#      field list for <some_struct>. Catches the BAPI_MARA-style trap
#      (LS_CLIENTDATA-GROSS_WT does not exist on this S/4HANA build) BEFORE
#      the source goes to SE38 and surfaces 9 syntax errors at upload time.
#
#   B) AUTHORITY-CHECK shape -- every `AUTHORITY-CHECK OBJECT '<X>' ID ...`
#      block is checked against the cached SU21 field list for <X>. Catches
#      SLIN's "Wrong number of authorization fields" Priority 2 storm BEFORE
#      ATC runs post-deploy.
#
# Inputs (tokens replaced by caller):
#   %%ABAP_FILE%%        Absolute path to the ABAP source file under check
#   %%STRUCT_SIG_FILE%%  Path to _struct_signatures.txt (may be missing / blank)
#   %%AUTHZ_SIG_FILE%%   Path to _authz_signatures.txt (may be missing / blank)
#   %%RESULT_FILE%%      Path to the existing .check.tsv (append; don't overwrite)
#
# Output: APPENDS rows to RESULT_FILE in the same TSV shape sap-check-abap uses:
#   Line<TAB>Severity<TAB>Class<TAB>Variable<TAB>Type<TAB>Reason<TAB>FixAdvice
#
# When a signature cache file is missing or empty, the corresponding check is
# silently skipped -- this validator is purely additive over the existing
# offline checks. Run AFTER sap_check_abap.vbs, before deploy.
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

$ABAP_FILE       = "%%ABAP_FILE%%"
$STRUCT_SIG_FILE = "%%STRUCT_SIG_FILE%%"
$AUTHZ_SIG_FILE  = "%%AUTHZ_SIG_FILE%%"
$RESULT_FILE     = "%%RESULT_FILE%%"

if (-not (Test-Path $ABAP_FILE)) {
    Write-Host "ERROR: ABAP file not found: $ABAP_FILE"
    exit 1
}

# ---- Load the source (strip comments per line; preserve line numbers) -------
$rawLines = Get-Content -LiteralPath $ABAP_FILE -Encoding UTF8
$lines = @()
for ($i = 0; $i -lt $rawLines.Count; $i++) {
    $raw = $rawLines[$i]
    # Strip full-line comments ("*" at column 0)
    if ($raw -match '^\*') {
        $lines += @{ N = $i + 1; Code = "" }
        continue
    }
    # Strip trailing inline comments (everything after `"`)
    $code = $raw
    $q = $code.IndexOf('"')
    if ($q -ge 0) { $code = $code.Substring(0, $q) }
    $lines += @{ N = $i + 1; Code = $code }
}

# ---- Result accumulator -----------------------------------------------------
$results = New-Object System.Collections.Generic.List[string]
function Add-Finding($lineNum, $severity, $class, $varName, $typ, $reason, $fix) {
    $results.Add("$lineNum`t$severity`t$class`t$varName`t$typ`t$reason`t$fix")
}

# ---- Build DATA-var -> type map (only top-level DATA declarations) ----------
# Supported shapes:
#   DATA lv_x TYPE bapi_mara.
#   DATA lt_x TYPE STANDARD TABLE OF bapi_mara WITH ...
#   DATA ls_x TYPE <struct>.
#   DATA(lv_x) = ...  (inline -- type unknown without RFC, skip)
$varToType = @{}
foreach ($l in $lines) {
    if ($l.Code -eq "") { continue }
    $t = $l.Code.Trim()
    # Match `DATA <name> TYPE <thing>...` and `DATA: <name> TYPE <thing>,...` (one entry at a time)
    $rx = '(?im)\b(?:DATA|CLASS-DATA|STATICS|FIELD-SYMBOLS?)[:]?\s+(<?[a-zA-Z_][a-zA-Z0-9_]*>?)\s+(?:TYPE|LIKE)\s+(?:STANDARD\s+TABLE\s+OF\s+|SORTED\s+TABLE\s+OF\s+|HASHED\s+TABLE\s+OF\s+|REF\s+TO\s+)?([a-zA-Z_][a-zA-Z0-9_]*)'
    foreach ($m in [regex]::Matches($t, $rx)) {
        $vname = $m.Groups[1].Value.ToUpper()
        $vtype = $m.Groups[2].Value.ToUpper()
        # Skip primitive ABAP type keywords that aren't DDIC structs
        if ($vtype -in @('C','N','P','I','D','T','F','X','STRING','XSTRING','TABLE','ANY','REF','HASHED','SORTED','STANDARD')) {
            continue
        }
        $varToType[$vname] = $vtype
    }
}

# ---- Load struct signature cache --------------------------------------------
# Format: TABNAME\tPOSITION\tFIELDNAME\tROLLNAME\tDOMNAME\tINTTYPE\tLENG\tDECIMALS\tKEYFLAG
$structFields = @{}      # key = TABNAME.ToUpper(), value = HashSet of fieldnames
$structNotFound = @{}    # tabnames with NOT_FOUND marker
$structUnavailable = $false
if ($STRUCT_SIG_FILE -ne "" -and (Test-Path $STRUCT_SIG_FILE)) {
    foreach ($row in Get-Content -LiteralPath $STRUCT_SIG_FILE) {
        $cols = $row.Split("`t")
        if ($cols.Count -lt 3) { continue }
        $tab = $cols[0].Trim().ToUpper()
        $pos = $cols[1].Trim()
        $fld = if ($cols.Count -ge 3) { $cols[2].Trim().ToUpper() } else { "" }
        if ($pos -eq "NOT_FOUND") {
            $structNotFound[$tab] = $true
            continue
        }
        if ($pos -eq "UNAVAILABLE") {
            $structUnavailable = $true
            continue
        }
        if ($fld -eq "") { continue }
        if (-not $structFields.ContainsKey($tab)) {
            $structFields[$tab] = New-Object 'System.Collections.Generic.HashSet[string]'
        }
        [void]$structFields[$tab].Add($fld)
    }
    Write-Host ("INFO: Struct cache loaded -- " + $structFields.Count + " struct(s) with field lists, " +
                $structNotFound.Count + " NOT_FOUND.")
} else {
    Write-Host "INFO: Struct cache absent -- skipping struct field validation."
}

# ---- A) Struct field reference validation -----------------------------------
# Walk each line for <var>-<field> patterns. Skip patterns inside string
# templates ( | ... | ) since those embed expressions, not field refs.
$nStructChecks = 0
$nStructErrors = 0
if ($structFields.Count -gt 0 -or $structNotFound.Count -gt 0) {
    foreach ($l in $lines) {
        $code = $l.Code
        if ($code -eq "") { continue }
        # Remove string templates and string literals
        $strippable = [regex]::Replace($code, '\|[^|]*\|', '')
        $strippable = [regex]::Replace($strippable, "'[^']*'", '')

        # Match <ident>-<ident> not preceded by another `-` (avoid type ref like FOO-BAR-BAZ middle)
        $refRx = '(?<![A-Za-z0-9_-])([A-Za-z_][A-Za-z0-9_]*)-([A-Za-z_][A-Za-z0-9_]*)'
        foreach ($m in [regex]::Matches($strippable, $refRx)) {
            $vname = $m.Groups[1].Value.ToUpper()
            $field = $m.Groups[2].Value.ToUpper()

            # Skip if not a known DATA var (could be a SELECT alias, DDIC table ref like MARA-MATNR, etc.)
            if (-not $varToType.ContainsKey($vname)) { continue }
            $typ = $varToType[$vname]

            if ($structNotFound.ContainsKey($typ)) {
                $nStructChecks++
                $nStructErrors++
                Add-Finding $l.N "ERROR" "STRUCT_TYPE_MISSING" $vname $typ `
                    "Type $typ does not exist on the target SAP system (per _struct_signatures.txt NOT_FOUND)." `
                    "Check spec / FM signature -- may be a typo or release-removed structure."
                continue
            }

            if (-not $structFields.ContainsKey($typ)) {
                # Type wasn't in the cache. Could be: (a) cache was generated against a different FM list and this struct wasn't included, (b) the type is a primitive / local ABAP type. Either way we can't validate -- skip silently.
                continue
            }

            $nStructChecks++
            if (-not $structFields[$typ].Contains($field)) {
                $nStructErrors++
                Add-Finding $l.N "ERROR" "STRUCT_FIELD_MISSING" "$vname-$field" $typ `
                    "Field $field does not exist on $typ (per live DDIF_FIELDINFO_GET in _struct_signatures.txt)." `
                    "Verify the field name against SE11 $typ, or route the value via the correct BAPI parameter (e.g. marmdata for MARM-resident fields per rule 22)."
            }
        }
    }
    Write-Host ("INFO: Checked " + $nStructChecks + " struct field reference(s); " +
                $nStructErrors + " error(s) found.")
}

# ---- Load AUTHX signature cache --------------------------------------------
# Format: OBJCT\tPOSITION\tFIELD
$authzFields = @{}       # key = OBJCT.ToUpper(), value = ordered List[string] of fieldnames
$authzNotFound = @{}
$authzUnavailable = $false
if ($AUTHZ_SIG_FILE -ne "" -and (Test-Path $AUTHZ_SIG_FILE)) {
    foreach ($row in Get-Content -LiteralPath $AUTHZ_SIG_FILE) {
        $cols = $row.Split("`t")
        if ($cols.Count -lt 3) { continue }
        $obj = $cols[0].Trim().ToUpper()
        $pos = $cols[1].Trim()
        $fld = $cols[2].Trim().ToUpper()
        if ($pos -eq "NOT_FOUND") {
            $authzNotFound[$obj] = $true
            continue
        }
        if ($pos -eq "UNAVAILABLE") {
            $authzUnavailable = $true
            continue
        }
        if ($fld -eq "") { continue }
        if (-not $authzFields.ContainsKey($obj)) {
            $authzFields[$obj] = New-Object 'System.Collections.Generic.List[string]'
        }
        [void]$authzFields[$obj].Add($fld)
    }
    Write-Host ("INFO: AUTHX cache loaded -- " + $authzFields.Count + " object(s), " +
                $authzNotFound.Count + " NOT_FOUND.")
} else {
    Write-Host "INFO: AUTHX cache absent -- skipping AUTHORITY-CHECK shape validation."
}

# ---- B) AUTHORITY-CHECK shape validation -----------------------------------
# AUTHORITY-CHECK statements span multiple lines. Reconstruct them by joining
# consecutive non-comment lines from the keyword to the terminating period.
$nAuthzChecks = 0
$nAuthzErrors = 0
if ($authzFields.Count -gt 0 -or $authzNotFound.Count -gt 0) {
    $i = 0
    while ($i -lt $lines.Count) {
        $code = $lines[$i].Code.Trim()
        if ($code -match '(?i)^\s*AUTHORITY-CHECK\s+OBJECT') {
            $startLine = $lines[$i].N
            # Accumulate until period
            $acc = $code
            while ($acc -notmatch '\.\s*$' -and ($i + 1) -lt $lines.Count) {
                $i++
                $acc += " " + $lines[$i].Code.Trim()
            }
            $i++
            # Parse: AUTHORITY-CHECK OBJECT '<X>' ID '<f1>' (FIELD ... | DUMMY) ID '<f2>' ...
            $objMatch = [regex]::Match($acc, "(?i)AUTHORITY-CHECK\s+OBJECT\s+'([^']+)'")
            if (-not $objMatch.Success) { continue }
            $objName = $objMatch.Groups[1].Value.ToUpper()
            $idMatches = [regex]::Matches($acc, "(?i)ID\s+'([^']+)'")
            $sourceFields = @()
            foreach ($im in $idMatches) { $sourceFields += $im.Groups[1].Value.ToUpper() }

            $nAuthzChecks++

            if ($authzNotFound.ContainsKey($objName)) {
                $nAuthzErrors++
                Add-Finding $startLine "ERROR" "AUTHZ_OBJECT_MISSING" $objName "" `
                    "Auth object $objName does not exist on the target SAP system (per _authz_signatures.txt NOT_FOUND)." `
                    "Verify the object name in SU21, or create the Z-namespace object first."
                continue
            }

            if (-not $authzFields.ContainsKey($objName)) {
                # Not in cache (e.g. cache was for a different object set). Skip.
                continue
            }

            $live = $authzFields[$objName]
            # Count check
            if ($sourceFields.Count -ne $live.Count) {
                $nAuthzErrors++
                $liveList = $live -join ", "
                $srcList = $sourceFields -join ", "
                Add-Finding $startLine "ERROR" "AUTHZ_FIELD_COUNT" $objName "" `
                    "Source passes $($sourceFields.Count) ID clause(s); SU21 defines $($live.Count) field(s): [$liveList]." `
                    "Add ID clauses for every SU21 field (use DUMMY for unused). Source has: [$srcList]."
                continue
            }
            # Field-name check (order-independent -- SLIN doesn't require order)
            $missingFields = @()
            foreach ($lf in $live) { if ($sourceFields -notcontains $lf) { $missingFields += $lf } }
            $extraFields = @()
            foreach ($sf in $sourceFields) { if ($live -notcontains $sf) { $extraFields += $sf } }
            if ($missingFields.Count -gt 0 -or $extraFields.Count -gt 0) {
                $nAuthzErrors++
                $miss = $missingFields -join ", "
                $extra = $extraFields -join ", "
                $reasonParts = @()
                if ($miss) { $reasonParts += "missing: [$miss]" }
                if ($extra) { $reasonParts += "extra: [$extra]" }
                Add-Finding $startLine "ERROR" "AUTHZ_FIELD_NAME" $objName "" `
                    ("Field-name mismatch vs SU21: " + ($reasonParts -join "; ")) `
                    "Use the SU21 field names exactly (use DUMMY for fields not gated by this check)."
            }
        } else {
            $i++
        }
    }
    Write-Host ("INFO: Checked " + $nAuthzChecks + " AUTHORITY-CHECK statement(s); " +
                $nAuthzErrors + " error(s) found.")
}

# ---- Append to result file --------------------------------------------------
if ($results.Count -gt 0) {
    # If file doesn't exist yet, write a header. If it exists, just append.
    if (-not (Test-Path $RESULT_FILE)) {
        Set-Content -LiteralPath $RESULT_FILE -Value "Line`tSeverity`tClass`tVariable`tType`tReason`tFixAdvice" -Encoding UTF8
    }
    Add-Content -LiteralPath $RESULT_FILE -Value $results -Encoding UTF8
    Write-Host ("INFO: Appended " + $results.Count + " finding(s) to " + $RESULT_FILE)
} else {
    Write-Host "INFO: No signature-validation findings to append."
}

if ($structUnavailable -or $authzUnavailable) {
    Write-Host "WARN: One or more signature caches were UNAVAILABLE (RFC unreachable at gen time). Some checks were skipped."
}

exit 0
