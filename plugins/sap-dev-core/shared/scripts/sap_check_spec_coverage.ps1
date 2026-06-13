# =============================================================================
# sap_check_spec_coverage.ps1  -  Spec-coverage validator for generated ABAP
#
# OFFLINE, no SAP. The "did the generated code cover my spec?" check: it derives
# the EXPECTED coverage from the spec extraction files (/sap-docs-extract output)
# and confirms the generator's own manifest siblings honoured it. This catches
# a whole regression class the per-file lint cannot see -- a dropped dependency,
# a missing error message, a selection field that never made it onto the screen.
#
# It is the user-facing twin of the CI regression net scripts/diff-abap-skeleton.mjs:
# the CI version diffs against a committed golden skeleton (case.json); this one
# derives the skeleton from the user's OWN spec, so it works on any fresh build.
#
# Compared (all in the same {work_folder} as the .abap):
#   spec  <doc>_deps.txt              -> generated <stem>.deps.txt        (dependency presence)
#   spec  <doc>_errorMsgs.txt         -> generated <stem>.messages.txt    (message-id presence)
#   spec  <doc>_textElements.txt      -> generated <stem>.text_elements.txt [TEXT_SYMBOLS] (presence)
#   spec  <doc>_selection_definition.txt -> [SELECTION_TEXTS]             (field count)
#   generated <stem>.traceability.txt -> (informational category rollup)
#
# Spec files use a `<doc>_` prefix; generated manifests use a `<stem>.` prefix --
# different separators -- so they are located by glob, not derived from the stem.
#
# BOUNDARY: this is a STRUCTURAL coverage check (presence + counts). It cannot
# verify the logic INSIDE a validation (right field, right operator) -- that is
# the live ABAP Unit run on the _golden.txt rows. Dependency matching is
# best-effort name matching, hence WARNING severity (not a hard gate).
#
# Inputs (tokens replaced by caller):
#   %%ABAP_FILE%%    Absolute path to the generated ABAP source file
#   %%RESULT_FILE%%  Path to the existing .check.tsv (append; never overwrite)
#
# Output: APPENDS rows in the canonical sap-check-abap shape:
#   CHECK_TYPE<TAB>SEVERITY<TAB>LINE<TAB>VARIABLE<TAB>SCOPE<TAB>DATA_KIND<TAB>DETAIL<TAB>FIX_ADVICE
# New finding codes: SPEC_DEP_MISSING, SPEC_MESSAGE_MISSING, SPEC_TEXTSYM_MISSING,
#   SPEC_SELECTION_COUNT (all WARNING), SPEC_TRACEABILITY_INFO (INFO).
#
# When the spec files or generated manifests are absent, the corresponding check
# is silently skipped -- purely additive. Run AFTER sap_check_abap.vbs.
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
$stem       = [System.IO.Path]::GetFileNameWithoutExtension($ABAP_FILE)

# ---- locate generated manifests (stem. prefix) ------------------------------
$genDeps  = Join-Path $workFolder ($stem + ".deps.txt")
$genMsgs  = Join-Path $workFolder ($stem + ".messages.txt")
$genText  = Join-Path $workFolder ($stem + ".text_elements.txt")
$genTrace = Join-Path $workFolder ($stem + ".traceability.txt")

# ---- locate spec extraction files (doc_ prefix; glob) -----------------------
function First-Match($pat) {
    $f = Get-ChildItem -LiteralPath $workFolder -Filter $pat -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    return ""
}
$specDeps   = First-Match '*_deps.txt'
$specMsgs   = First-Match '*_errorMsgs.txt'
$specText   = First-Match '*_textElements.txt'
$specSelDef = First-Match '*_selection_definition.txt'

if ($specDeps -eq "" -and $specMsgs -eq "" -and $specText -eq "" -and $specSelDef -eq "") {
    Write-Host "INFO: No spec extraction files (*_deps/_errorMsgs/_textElements/_selection_definition.txt) in work folder -- skipping spec-coverage check."
    exit 0
}

$results = New-Object System.Collections.Generic.List[string]
function Add-Cov($checkType, $severity, $varName, $detail, $fix) {
    $results.Add(($checkType + "`t" + $severity + "`t0`t" + $varName + "`tSPEC`tCOVERAGE`t" + $detail + "`t" + $fix))
}

# ---- parse generated manifests into lookup sets -----------------------------
$genDepNames = New-Object 'System.Collections.Generic.HashSet[string]'
$depSections = @('STANDARD_TABLES','BAPIS','CLASSES','AUTHZ_OBJECTS','CUSTOM_OBJECTS')
if (Test-Path -LiteralPath $genDeps) {
    foreach ($r in Get-Content -LiteralPath $genDeps -Encoding UTF8) {
        $t = $r.Trim().ToUpper()
        if ($t -eq "" -or ($depSections -contains $t)) { continue }
        [void]$genDepNames.Add($t)
    }
}

$genMsgIds = New-Object 'System.Collections.Generic.HashSet[string]'
if (Test-Path -LiteralPath $genMsgs) {
    foreach ($r in Get-Content -LiteralPath $genMsgs -Encoding UTF8) {
        $id = ($r -split "`t")[0].Trim()
        if ($id -match '^\d{1,3}$') { [void]$genMsgIds.Add($id.PadLeft(3,'0')) }
    }
}

$genTextSyms = New-Object 'System.Collections.Generic.HashSet[string]'
$genSelCount = 0
if (Test-Path -LiteralPath $genText) {
    $block = ""
    foreach ($r in Get-Content -LiteralPath $genText -Encoding UTF8) {
        $t = $r.Trim()
        if ($t -match '^\[SELECTION_TEXTS\]') { $block = "sel"; continue }
        if ($t -match '^\[TEXT_SYMBOLS\]')    { $block = "sym"; continue }
        if ($t -match '^\[')                  { $block = "";    continue }
        if ($t -eq "") { continue }
        if ($block -eq "sel") { $genSelCount++ }
        elseif ($block -eq "sym") {
            $id = (($t -split "`t")[0]).Trim()
            if ($id -match '^\d{1,3}$') { [void]$genTextSyms.Add($id.PadLeft(3,'0')) }
        }
    }
}

# ---- 1) dependency coverage (best-effort name matching; WARNING) ------------
if ($specDeps -ne "" -and (Test-Path -LiteralPath $genDeps)) {
    $stop = @('FM','BAPI','BAPIS','CLASS','CLASSES','FUNCTION','MODULE','METHOD',
              'INTERFACE','TABLE','TABLES','STRUCTURE','DEPENDENCY','DEPENDENCIES',
              'AUTH','AUTHORIZATION','AUTHORIZATIONS','OBJECT','OBJECTS','NAME','NAMES',
              'TYPE','KIND','STANDARD_TABLES','AUTHZ_OBJECTS','CUSTOM_OBJECTS','NOTE','DESC')
    $specDepNames = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($r in Get-Content -LiteralPath $specDeps -Encoding UTF8) {
        $line = $r.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { continue }
        foreach ($tok in ($line -split '[\t ,;|]+')) {
            $u = $tok.Trim().ToUpper()
            if ($u -match '^[A-Z][A-Z0-9_/]{2,}$' -and ($stop -notcontains $u)) { [void]$specDepNames.Add($u) }
        }
    }
    $missDeps = 0
    foreach ($d in $specDepNames) {
        if (-not $genDepNames.Contains($d)) {
            Add-Cov 'SPEC_DEP_MISSING' 'WARNING' $d `
                ("spec lists dependency " + $d + " but it is absent from " + $stem + ".deps.txt") `
                ("Confirm the generated code uses " + $d + ", or remove it from the spec dependencies")
            $missDeps++
        }
    }
    Write-Host ("INFO: spec deps checked (" + $specDepNames.Count + "); " + $missDeps + " not covered.")
}

# ---- 2) message-id coverage (numeric ids; WARNING) --------------------------
if ($specMsgs -ne "" -and (Test-Path -LiteralPath $genMsgs)) {
    $specMsgIds = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($r in Get-Content -LiteralPath $specMsgs -Encoding UTF8) {
        $id = ($r -split "`t")[0].Trim()
        if ($id -match '^\d{1,3}$') { [void]$specMsgIds.Add($id.PadLeft(3,'0')) }
    }
    $missMsg = 0
    foreach ($m in $specMsgIds) {
        if (-not $genMsgIds.Contains($m)) {
            Add-Cov 'SPEC_MESSAGE_MISSING' 'WARNING' ("MSG" + $m) `
                ("spec error message " + $m + " was not emitted in " + $stem + ".messages.txt") `
                ("Ensure the generated code raises message " + $m + ", or remove it from the spec")
            $missMsg++
        }
    }
    Write-Host ("INFO: spec messages checked (" + $specMsgIds.Count + "); " + $missMsg + " not covered.")
}

# ---- 3) text-symbol coverage (numeric ids; WARNING) -------------------------
if ($specText -ne "" -and (Test-Path -LiteralPath $genText)) {
    $specTextIds = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($r in Get-Content -LiteralPath $specText -Encoding UTF8) {
        $id = ($r -split "`t")[0].Trim()
        if ($id -match '^\d{1,3}$') { [void]$specTextIds.Add($id.PadLeft(3,'0')) }
    }
    $missText = 0
    foreach ($s in $specTextIds) {
        if (-not $genTextSyms.Contains($s)) {
            Add-Cov 'SPEC_TEXTSYM_MISSING' 'WARNING' ("TEXT-" + $s) `
                ("spec text element " + $s + " is absent from [TEXT_SYMBOLS] in " + $stem + ".text_elements.txt") `
                ("Add the text symbol to the generated text pool, or remove it from the spec")
            $missText++
        }
    }
    Write-Host ("INFO: spec text symbols checked (" + $specTextIds.Count + "); " + $missText + " not covered.")
}

# ---- 4) selection-field count (count, prefix-tolerant; WARNING) -------------
if ($specSelDef -ne "" -and (Test-Path -LiteralPath $genText)) {
    $specSelCount = 0
    $firstRow = $true
    foreach ($r in Get-Content -LiteralPath $specSelDef -Encoding UTF8) {
        $t = $r.Trim()
        if ($t -eq "" -or $t.StartsWith("#")) { continue }
        if ($firstRow) {
            $firstRow = $false
            # skip a header row (starts with "NO" or contains LABEL/DTEL_NAME)
            if ($t -match '(?i)^NO\b' -or $t -match '(?i)\bLABEL\b' -or $t -match '(?i)\bDTEL_NAME\b') { continue }
        }
        $specSelCount++
    }
    if ($specSelCount -ne $genSelCount) {
        Add-Cov 'SPEC_SELECTION_COUNT' 'WARNING' 'SELECTION' `
            ("spec defines " + $specSelCount + " selection field(s) but [SELECTION_TEXTS] has " + $genSelCount) `
            ("Check every selection-screen field maps to a PARAMETERS/SELECT-OPTIONS line and a selection text")
    }
    Write-Host ("INFO: spec selection fields=" + $specSelCount + ", generated selection texts=" + $genSelCount + ".")
}

# ---- 5) traceability category rollup (informational) ------------------------
if (Test-Path -LiteralPath $genTrace) {
    $cv = 0; $pr = 0; $fm = 0; $other = 0
    foreach ($r in Get-Content -LiteralPath $genTrace -Encoding UTF8) {
        $m = [regex]::Match($r, '^\s*\[([^\]]+)\]')
        if (-not $m.Success) { continue }
        $tag = $m.Groups[1].Value.ToUpper()
        if ($tag.StartsWith('VALIDATION'))      { $cv++ }
        elseif ($tag.StartsWith('PROCESSING'))  { $pr++ }
        elseif ($tag.StartsWith('FILE MAPPING')){ $fm++ }
        else                                    { $other++ }
    }
    Add-Cov 'SPEC_TRACEABILITY_INFO' 'INFO' 'TRACEABILITY' `
        ("traceability entries: " + $cv + " validation, " + $pr + " processing, " + $fm + " file-mapping, " + $other + " other") `
        ("Review that every spec validation / processing rule appears in " + $stem + ".traceability.txt")
    Write-Host ("INFO: traceability: " + $cv + " validation, " + $pr + " processing, " + $fm + " file-mapping, " + $other + " other.")
}

# ---- append to result file --------------------------------------------------
if ($results.Count -gt 0) {
    if (-not (Test-Path -LiteralPath $RESULT_FILE)) {
        Set-Content -LiteralPath $RESULT_FILE -Value "CHECK_TYPE`tSEVERITY`tLINE`tVARIABLE`tSCOPE`tDATA_KIND`tDETAIL`tFIX_ADVICE" -Encoding UTF8
    }
    Add-Content -LiteralPath $RESULT_FILE -Value $results -Encoding UTF8
    Write-Host ("INFO: Appended " + $results.Count + " spec-coverage finding(s) to " + $RESULT_FILE)
} else {
    Write-Host "INFO: No spec-coverage findings to append."
}

exit 0
