# =============================================================================
# sap_check_conversion.ps1  -  Internal/external conversion checks for generated ABAP
#
# OFFLINE, no SAP. Catches at CHECK time the two conversion defects that survive
# syntax + activation + ATC and only show as wrong data at runtime (the class the
# gen-time rule abap_code_quality_rules.md "Internal/external conversion at file
# boundaries" + the frequently_errors STMT seeds steer away from):
#
#   (a) CONV_CURR_MISSING_REF      - a CURR/QUAN file column is mapped to a SAP
#       field but its reference field (currency CUKY / unit UNIT) is NOT mapped.
#       An amount/quantity is uninterpretable without its currency/unit (the
#       decimal count comes from it: TCURX-CURRDEC / T006-DECAN). e.g. VBAP-NETPR
#       needs VBAP-WAERK.
#   (b) CONV_CURR_DISPLAY_TO_BAPI  - the source calls CURRENCY_AMOUNT_DISPLAY_TO_SAP
#       (external->internal) AND uses a BAPI amount type (BAPICURR / BAPICUREXT /
#       BAPICURR_D). BAPI amount fields already carry the EXTERNAL amount and shift
#       internally, so feeding them a pre-converted (internal) value double-shifts
#       (e.g. 100x for JPY). Verify the converted value goes ONLY to a raw DDIC
#       CURR field, never into a BAPI amount field.
#
# Inputs (tokens replaced by caller):
#   %%ABAP_FILE%%    Absolute path to the generated ABAP source file
#   %%RESULT_FILE%%  Path to the existing .check.tsv (APPEND; never overwrite)
#
# Output: APPENDS rows in the canonical sap-check-abap shape:
#   CHECK_TYPE<TAB>SEVERITY<TAB>LINE<TAB>VARIABLE<TAB>SCOPE<TAB>DATA_KIND<TAB>DETAIL<TAB>FIX_ADVICE
# New finding codes: CONV_CURR_MISSING_REF, CONV_CURR_DISPLAY_TO_BAPI (both WARNING).
#
# Data sources (all in the same {work_folder} as the .abap; each optional ->
# the corresponding check is silently skipped, purely additive):
#   *_file_mapping_in.txt / *_file_mapping_out.txt  (sap-docs-extract; header:
#       NO FILE_FIELD DATATYPE LENGTH ... SAP_TABLE SAP_FIELD)
#   _struct_signatures.txt  (sap_rfc_lookup_struct.ps1; 13-col rows carry
#       DATATYPE/CONVEXIT/REFTABLE/REFFIELD -> enables the PRECISE per-field
#       reference check; 9-col legacy rows -> coarse program-level fallback)
#
# Run AFTER sap_check_abap.vbs (so the result file + its header exist).
# =============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

$ABAP_FILE   = "%%ABAP_FILE%%"
$RESULT_FILE = "%%RESULT_FILE%%"

if (-not (Test-Path -LiteralPath $ABAP_FILE)) {
    Write-Host "ERROR: ABAP file not found: $ABAP_FILE"
    exit 1
}

$workFolder = Split-Path -Parent $ABAP_FILE

$results = New-Object System.Collections.Generic.List[string]
function Add-Find($code, $sev, $line, $var, $detail, $fix) {
    $results.Add($code + "`t" + $sev + "`t" + $line + "`t" + $var + "`tCONV`tCONVERSION`t" + $detail + "`t" + $fix)
}
function First-Match($pat) {
    $f = Get-ChildItem -LiteralPath $workFolder -Filter $pat -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    return ""
}

# ---- load struct signatures (13-col => precise; else coarse) -----------------
# Key "TABLE|FIELD" -> @{ datatype; reffield }. Only populated from 13-col rows.
$structInfo = @{}
$structHasNewCols = $false
$structFile = Join-Path $workFolder "_struct_signatures.txt"
if (-not (Test-Path -LiteralPath $structFile)) { $structFile = First-Match '*struct_signatures*.txt' }
if ($structFile -ne "" -and (Test-Path -LiteralPath $structFile)) {
    foreach ($r in Get-Content -LiteralPath $structFile -Encoding UTF8) {
        if ($r.Trim() -eq "") { continue }
        $c = $r -split "`t"
        if ($c.Count -lt 13) { continue }      # legacy/NOT_FOUND/UNAVAILABLE rows
        $tab = $c[0].Trim().ToUpper()
        $fld = $c[2].Trim().ToUpper()
        if ($tab -eq "" -or $fld -eq "") { continue }
        $structHasNewCols = $true
        $structInfo["$tab|$fld"] = @{ datatype = $c[9].Trim().ToUpper(); reffield = $c[12].Trim().ToUpper() }
    }
}

# ---- parse a file-mapping file (header-aware) into mapped amount/ref sets -----
# Returns: @{ mapped=HashSet "TAB|FLD"; amounts=List @{tab;fld;dt}; nCuky; nUnit }
function Parse-Mapping($path) {
    $mapped  = New-Object 'System.Collections.Generic.HashSet[string]'
    $amounts = New-Object System.Collections.Generic.List[object]
    $nCuky = 0; $nUnit = 0
    $lines = @(Get-Content -LiteralPath $path -Encoding UTF8)
    if ($lines.Count -eq 0) { return @{ mapped=$mapped; amounts=$amounts; nCuky=0; nUnit=0; rows=0 } }
    $hdr = $lines[0] -split "`t"
    $iDt = -1; $iTab = -1; $iFld = -1
    for ($i = 0; $i -lt $hdr.Count; $i++) {
        switch ($hdr[$i].Trim().ToUpper()) {
            'DATATYPE'  { $iDt  = $i }
            'SAP_TABLE' { $iTab = $i }
            'SAP_FIELD' { $iFld = $i }
        }
    }
    if ($iTab -lt 0 -or $iFld -lt 0) { return @{ mapped=$mapped; amounts=$amounts; nCuky=0; nUnit=0; rows=0 } }
    $rows = 0
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $cols = $lines[$i] -split "`t"
        if ($cols.Count -le $iFld) { continue }
        $tab = $cols[$iTab].Trim().ToUpper()
        $fld = $cols[$iFld].Trim().ToUpper()
        $dt  = if ($iDt -ge 0 -and $cols.Count -gt $iDt) { $cols[$iDt].Trim().ToUpper() } else { "" }
        if ($tab -ne "" -and $fld -ne "") { [void]$mapped.Add("$tab|$fld") }
        if ($dt -eq 'CUKY') { $nCuky++ }
        elseif ($dt -eq 'UNIT') { $nUnit++ }
        if (($dt -eq 'CURR' -or $dt -eq 'QUAN') -and $tab -ne "" -and $fld -ne "") {
            $amounts.Add(@{ tab=$tab; fld=$fld; dt=$dt })
        }
        $rows++
    }
    return @{ mapped=$mapped; amounts=$amounts; nCuky=$nCuky; nUnit=$nUnit; rows=$rows }
}

# ---- (a) CURR/QUAN reference-field coverage ---------------------------------
foreach ($mapPat in @('*_file_mapping_in.txt', '*_file_mapping_out.txt')) {
    $mapFile = First-Match $mapPat
    if ($mapFile -eq "") { continue }
    $m = Parse-Mapping $mapFile
    if ($m.rows -eq 0 -or $m.amounts.Count -eq 0) { continue }
    if ($structHasNewCols) {
        # PRECISE: each amount must have its specific REFFIELD mapped on its table.
        foreach ($a in $m.amounts) {
            $info = $structInfo["$($a.tab)|$($a.fld)"]
            if ($null -eq $info) { continue }                 # field not in struct cache -> skip
            if ($info.datatype -ne 'CURR' -and $info.datatype -ne 'QUAN') { continue }
            $ref = $info.reffield
            if ($ref -eq "" -or $ref -eq " ") { continue }    # no reference defined on this field
            if (-not $m.mapped.Contains("$($a.tab)|$ref")) {
                $kind = if ($info.datatype -eq 'CURR') { 'currency (CUKY)' } else { 'unit (UNIT)' }
                Add-Find 'CONV_CURR_MISSING_REF' 'WARNING' 0 "$($a.tab)-$($a.fld)" `
                    ("$($info.datatype) field $($a.tab)-$($a.fld) is file-mapped but its reference $kind field $($a.tab)-$ref is not mapped; the amount's decimal count is undefined without it") `
                    ("Map $($a.tab)-$ref in the file layout (or default it in code before the write); a CURR/QUAN value is uninterpretable without its currency/unit")
            }
        }
    } else {
        # COARSE fallback (no 13-col struct cache): amounts present but zero
        # reference fields of the needed kind mapped anywhere.
        $hasCurr = @($m.amounts | Where-Object { $_.dt -eq 'CURR' }).Count
        $hasQuan = @($m.amounts | Where-Object { $_.dt -eq 'QUAN' }).Count
        if ($hasCurr -gt 0 -and $m.nCuky -eq 0) {
            Add-Find 'CONV_CURR_MISSING_REF' 'WARNING' 0 'CURR' `
                ("$hasCurr CURR (amount) file column(s) mapped but no currency (CUKY) column is mapped in $(Split-Path -Leaf $mapFile)") `
                ('Map the document currency (a CUKY field) alongside the amount; without it the decimal count is undefined (TCURX-CURRDEC). Re-run with RFC so struct signatures name the exact reference field.')
        }
        if ($hasQuan -gt 0 -and $m.nUnit -eq 0) {
            Add-Find 'CONV_CURR_MISSING_REF' 'WARNING' 0 'QUAN' `
                ("$hasQuan QUAN (quantity) file column(s) mapped but no unit (UNIT) column is mapped in $(Split-Path -Leaf $mapFile)") `
                ('Map the unit of measure (a UNIT field) alongside the quantity; decimals come from the unit (T006-DECAN). Re-run with RFC so struct signatures name the exact reference field.')
        }
    }
}

# ---- (b) DISPLAY_TO_SAP feeding a BAPI amount type (double-shift smell) ------
$src = Get-Content -LiteralPath $ABAP_FILE -Encoding UTF8
$displayLine = 0
$hasBapiAmt = $false
for ($i = 0; $i -lt $src.Count; $i++) {
    $u = $src[$i].ToUpper()
    if ($displayLine -eq 0 -and $u -match 'CURRENCY_AMOUNT_DISPLAY_TO_SAP') { $displayLine = $i + 1 }
    if (-not $hasBapiAmt -and $u -match 'BAPICURR(_D|EXT)?') { $hasBapiAmt = $true }
}
if ($displayLine -gt 0 -and $hasBapiAmt) {
    Add-Find 'CONV_CURR_DISPLAY_TO_BAPI' 'WARNING' $displayLine 'CURRENCY_AMOUNT_DISPLAY_TO_SAP' `
        ('CURRENCY_AMOUNT_DISPLAY_TO_SAP (external->internal) is used in a program that also uses a BAPI amount type (BAPICURR/BAPICUREXT/BAPICURR_D); feeding a pre-converted internal amount into a BAPI amount field double-shifts (e.g. 100x for JPY)') `
        ('BAPI amount fields take the EXTERNAL amount and shift internally - pass the parsed external value straight in. Use CURRENCY_AMOUNT_DISPLAY_TO_SAP ONLY for raw DDIC CURR field writes, never before a BAPICURR field.')
}

# ---- append to result file --------------------------------------------------
if ($results.Count -gt 0) {
    if (-not (Test-Path -LiteralPath $RESULT_FILE)) {
        Set-Content -LiteralPath $RESULT_FILE -Value "CHECK_TYPE`tSEVERITY`tLINE`tVARIABLE`tSCOPE`tDATA_KIND`tDETAIL`tFIX_ADVICE" -Encoding UTF8
    }
    Add-Content -LiteralPath $RESULT_FILE -Value $results -Encoding UTF8
    Write-Host ("INFO: Appended " + $results.Count + " conversion finding(s) to " + $RESULT_FILE)
} else {
    Write-Host "INFO: No conversion findings to append."
}

exit 0
