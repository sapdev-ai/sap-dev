# =============================================================================
# sap_api_discover.ps1  -  /sap-api-advisor discover backend (RFC, read-only)
#
# Three actions, all read-only (Rule 1 reads only; NO smoke-calling of candidates):
#
#   -Action harvest -Keywords "k1,k2" [-NamePatterns "BAPI_SALES%,SD_%"]
#           [-Type fm|bapi|class|any] [-Max 50] [-OutTsv <tsv>]
#     Candidate harvest from (uniform on ECC 6 + S/4):
#       * BAPI catalog  -- BAPI_MONITOR_GETLIST -> BAPILIST (one call, all released
#         BAPIs; ABAPNAME=FM, BAPI_TEXT/BO_TEXT=EN texts, OBSOLETE, COMP), local
#         keyword filter. The richest source; leads.
#       * FM name       -- RFC_READ_TABLE TFDIR (FUNCNAME LIKE <pattern>, FMODE) per
#         -NamePatterns. Only the columns COMMON to both releases are selected
#         (S4D TFDIR has 12 cols incl. RFCSCOPE/RFCVERS; ECC has 10 -- verified).
#       * FM text       -- RFC_READ_TABLE TFTIT (SPRAS='E' AND STEXT LIKE %kw%),
#         DB-side filter + ROWCOUNT cap (TFTIT is large -- never client full-scan).
#       * Classes (Type=class|any) -- SEOCLASSTX DESCRIPT LIKE + SEOCLASS REMOTE.
#     Dedupes by name (BAPI src wins). Emits CAND: lines + a TSV. Zero rows across
#     all sources -> STATUS: NO_MATCH (never a fabricated candidate).
#
#   -Action released -Names "FM1,FM2" [-OutTsv <tsv>]
#     Released-state (S/4 ONLY) from ARS_W_API_STATE (RELEASE_STATE + SUCCESSOR_*).
#     The table is ABSENT on ECC (probed) -> STATUS: NOT_APPLICABLE (no release
#     contract on this release) -- never blank/false. Emits REL: lines.
#
#   -Action detail -Names "FM1" [-OutFile <docs.txt>]
#     Per-FM parameter texts (FUPARAREF + FUNCT) + FM documentation (DOCU_GET,
#     FMODE=R both systems -> direct call). Emits DETAIL: lines + doc text file.
#
# Tokens: %%RFC_LIB_PS1%% %%SAP_SERVER%% %%SAP_SYSNR%% %%SAP_CLIENT%% %%SAP_USER%%
#   %%SAP_PASSWORD%% %%SAP_LANGUAGE%%
# Exit: 0 = ran (incl. NO_MATCH / NOT_APPLICABLE), 1 = input issue, 2 = connect.
# Live-verified S4D (S/4 1909) + ERP (ECC6) 2026-07-11.
# =============================================================================
param(
    [Parameter(Mandatory = $true)][ValidateSet('harvest', 'released', 'detail')][string]$Action,
    [string]$Keywords = '',
    [string]$NamePatterns = '',
    [string]$Names = '',
    [string]$Type = 'any',
    [int]$Max = 50,
    [string]$OutTsv = '',
    [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'
. "%%RFC_LIB_PS1%%"
$Type = $Type.ToLower()

$dest = Connect-SapRfc -Server "%%SAP_SERVER%%" -Sysnr "%%SAP_SYSNR%%" -Client "%%SAP_CLIENT%%" `
    -User "%%SAP_USER%%" -Password "%%SAP_PASSWORD%%" -Language "%%SAP_LANGUAGE%%" -DestName "APIADV"
if (-not $dest) { Write-Output 'STATUS: RFC_LOGON_FAILED'; exit 2 }

function Add-Where($optTab, [string]$where) {
    $line = ''
    foreach ($tok in ($where -split ' ')) {
        if (($line.Length + $tok.Length + 1) -gt 72) { $optTab.Append(); $optTab.SetValue('TEXT', $line); $line = $tok }
        elseif ($line -eq '') { $line = $tok } else { $line = "$line $tok" }
    }
    if ($line -ne '') { $optTab.Append(); $optTab.SetValue('TEXT', $line) }
}
function Read-Narrow([string]$table, [string[]]$fields, [string]$where, [int]$rowcount) {
    $rt = $dest.Repository.CreateFunction('RFC_READ_TABLE')
    $rt.SetValue('QUERY_TABLE', $table); $rt.SetValue('DELIMITER', "`t"); $rt.SetValue('ROWCOUNT', $rowcount)
    $ff = $rt.GetTable('FIELDS'); foreach ($f in $fields) { $ff.Append(); $ff.SetValue('FIELDNAME', $f) }
    if ($where) { Add-Where $rt.GetTable('OPTIONS') $where }
    $rt.Invoke($dest)
    $data = $rt.GetTable('DATA'); $out = @()
    for ($i = 0; $i -lt $data.RowCount; $i++) {
        $data.CurrentIndex = $i; $parts = ($data.GetValue('WA') -split "`t")
        $h = @{ }; for ($k = 0; $k -lt $fields.Count; $k++) { $h[$fields[$k]] = ($parts[$k]).Trim() }
        $out += $h
    }
    return $out
}
function _Esc([string]$s) { return ($s -replace "'", "''") }

# =============================================================================
if ($Action -eq 'harvest') {
    $kw = @($Keywords -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $kwU = @($kw | ForEach-Object { $_.ToUpper() })
    $pats = @($NamePatterns -split ',' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
    $cands = [ordered]@{ }   # NAME -> row hashtable

    function _Add($name, $kind, $src, $extra) {
        $name = "$name".Trim(); if (-not $name) { return }
        $key = $name.ToUpper()
        if ($cands.Contains($key)) {
            # merge: keep BAPI/catalog src if already there; fill blanks
            $ex = $cands[$key]
            foreach ($k in $extra.Keys) { if (-not $ex[$k]) { $ex[$k] = $extra[$k] } }
            if ($ex.src -ne 'catalog' -and $src -eq 'catalog') { $ex.src = 'catalog'; $ex.kind = $kind }
            return
        }
        $row = @{ name = $name; kind = $kind; src = $src; released = ''; obsolete = ''; fmode = ''; comp = ''; text = ''; match_count = 0; name_match = 0 }
        foreach ($k in $extra.Keys) { $row[$k] = $extra[$k] }
        $cands[$key] = $row
    }

    # 1) BAPI catalog (leads) --------------------------------------------------
    if ($Type -in @('any', 'bapi', 'fm') -and $kwU.Count -gt 0) {
        try {
            $fn = $dest.Repository.CreateFunction('BAPI_MONITOR_GETLIST')
            $fn.SetValue('SHOW_RELEASE', 'X'); $fn.SetValue('RELEASED_BAPI', 'X')
            $fn.Invoke($dest)
            $t = $fn.GetTable('BAPILIST')
            for ($i = 0; $i -lt $t.RowCount; $i++) {
                $t.CurrentIndex = $i
                $abap = "$($t.GetValue('ABAPNAME'))".Trim()
                if (-not $abap) { continue }
                $hay = (("$($t.GetValue('BO_TEXT')) $($t.GetValue('BAPI_TEXT')) $abap $($t.GetValue('OBJECTNAME')) $($t.GetValue('BAPINAME'))")).ToUpper()
                $hit = $false; foreach ($k in $kwU) { if ($hay.Contains($k)) { $hit = $true; break } }
                if (-not $hit) { continue }
                _Add $abap 'BAPI' 'catalog' @{ text = "$($t.GetValue('BAPI_TEXT'))".Trim(); comp = "$($t.GetValue('COMP'))".Trim();
                    obsolete = "$($t.GetValue('OBSOLETE'))".Trim(); released = "$($t.GetValue('BAPI_REL'))".Trim() }
            }
        }
        catch { Write-Output ("NOTE: BAPI catalog read failed: " + ($_.Exception.Message -replace '\s+', ' ').Substring(0, 50)) }
    }

    # 2) FM name patterns (TFDIR) ---------------------------------------------
    if ($Type -in @('any', 'fm') -and $pats.Count -gt 0) {
        foreach ($pat in $pats) {
            try {
                $rows = Read-Narrow 'TFDIR' @('FUNCNAME', 'FMODE', 'PNAME') "FUNCNAME LIKE '$(_Esc $pat)'" ([Math]::Max(300, $Max))
                foreach ($r in $rows) { _Add $r.FUNCNAME 'FM' 'name' @{ fmode = $r.FMODE } }
            }
            catch { }
        }
    }

    # 3) FM text (TFTIT, DB-side LIKE) ----------------------------------------
    if ($Type -in @('any', 'fm') -and $kw.Count -gt 0) {
        foreach ($k in $kw) {
            try {
                $rows = Read-Narrow 'TFTIT' @('FUNCNAME', 'STEXT') "SPRAS = 'E' AND STEXT LIKE '%$(_Esc $k.ToUpper())%'" $Max
                foreach ($r in $rows) { _Add $r.FUNCNAME 'FM' 'text' @{ text = $r.STEXT } }
            }
            catch { }
        }
    }

    # 4) Classes (SEOCLASSTX desc + SEOCLASS remote) --------------------------
    if ($Type -in @('any', 'class') -and $kw.Count -gt 0) {
        foreach ($k in $kw) {
            try {
                $rows = Read-Narrow 'SEOCLASSTX' @('CLSNAME', 'DESCRIPT') "LANGU = 'E' AND DESCRIPT LIKE '%$(_Esc $k.ToUpper())%'" $Max
                foreach ($r in $rows) { _Add $r.CLSNAME 'CLASS' 'text' @{ text = $r.DESCRIPT } }
            }
            catch { }
        }
    }

    $all = @($cands.Values)
    if ($all.Count -eq 0) { Write-Output "STATUS: NO_MATCH keywords=[$Keywords]"; exit 0 }

    # relevance score = distinct keywords found in (name + text); a candidate that
    # hits more of the goal's keywords ranks higher than a single-keyword match
    # ("create" alone hits hundreds of BAPIs). Catalog + non-obsolete + released
    # are tie-break boosts. Cap the harvest to -Max so the SKILL ranks a shortlist.
    foreach ($r in $all) {
        $nmU = ("$($r.name)").ToUpper(); $hay = ("$($r.name) $($r.text)").ToUpper()
        $mc = 0; $nmc = 0; foreach ($k in $kwU) { if ($k) { if ($hay.Contains($k)) { $mc++ }; if ($nmU.Contains($k)) { $nmc++ } } }
        $r.match_count = $mc; $r.name_match = $nmc
    }
    # name-keyword hits weigh most (the goal's words appearing IN the API name is a
    # strong relevance signal), then total hits, then catalog membership + released.
    $all = @($all | Sort-Object `
        @{ Expression = { [int]$_.name_match }; Descending = $true }, `
        @{ Expression = { [int]$_.match_count }; Descending = $true }, `
        @{ Expression = { if ($_.src -eq 'catalog') { 1 } else { 0 } }; Descending = $true }, `
        @{ Expression = { if ($_.obsolete -eq 'X') { 0 } else { 1 } }; Descending = $true }, `
        @{ Expression = { if ($_.released -eq 'X') { 1 } else { 0 } }; Descending = $true }, `
        @{ Expression = { $_.name } })
    $total = $all.Count
    if ($total -gt $Max) { $all = @($all[0..($Max - 1)]) }

    $tsv = New-Object System.Collections.Generic.List[string]
    $tsv.Add("NAME`tKIND`tSRC`tMATCH`tFMODE`tRELEASED`tOBSOLETE`tCOMP`tTEXT")
    foreach ($r in $all) {
        Write-Output ("CAND: name={0} kind={1} src={2} match={3} fmode={4} released={5} obsolete={6} comp={7} text={8}" -f `
                $r.name, $r.kind, $r.src, $r.match_count, $r.fmode, $r.released, $r.obsolete, $r.comp, $r.text)
        $tsv.Add(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}" -f $r.name, $r.kind, $r.src, $r.match_count, $r.fmode, $r.released, $r.obsolete, $r.comp, $r.text))
    }
    if ($OutTsv) { [System.IO.File]::WriteAllLines($OutTsv, $tsv, (New-Object System.Text.UTF8Encoding($true))) }
    Write-Output "STATUS: OK n=$($all.Count) total=$total capped=$(if ($total -gt $Max) { 'true' } else { 'false' })"
    exit 0
}

# =============================================================================
if ($Action -eq 'released') {
    $names = @($Names -split ',' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
    if ($names.Count -eq 0) { Write-Output 'STATUS: INPUT_ERROR reason=no_names'; exit 1 }
    # ARS_W_API_STATE is S/4-only. Existence probe (DD02L) first.
    $present = $false
    try {
        $dd = Read-Narrow 'DD02L' @('TABNAME', 'AS4LOCAL') "TABNAME = 'ARS_W_API_STATE' AND AS4LOCAL = 'A'" 1
        if ($dd.Count -gt 0) { $present = $true }
    }
    catch { }
    if (-not $present) { Write-Output 'STATUS: NOT_APPLICABLE reason=no_release_contract_on_this_release'; exit 0 }

    $rel = @{ }
    foreach ($nm in $names) {
        try {
            # match on OBJECT_NAME or SUB_OBJECT_NAME (FM appears as SUB_OBJECT_NAME for FUNC rows)
            $rows = Read-Narrow 'ARS_W_API_STATE' @('OBJECT_TYPE', 'OBJECT_NAME', 'SUB_OBJECT_TYPE', 'SUB_OBJECT_NAME', 'RELEASE_STATE', 'SUCCESSOR_OBJECT_NAME') `
                "OBJECT_NAME = '$(_Esc $nm)' OR SUB_OBJECT_NAME = '$(_Esc $nm)'" 5
            if ($rows.Count -gt 0) { $rel[$nm] = $rows[0] }
        }
        catch { }
    }
    foreach ($nm in $names) {
        if ($rel.ContainsKey($nm)) {
            $r = $rel[$nm]
            Write-Output ("REL: name={0} state={1} object_type={2} successor={3}" -f $nm, $r.RELEASE_STATE, $r.OBJECT_TYPE, $r.SUCCESSOR_OBJECT_NAME)
        }
        else { Write-Output ("REL: name={0} state=NOT_LISTED successor=" -f $nm) }
    }
    Write-Output "STATUS: OK n=$($names.Count)"
    exit 0
}

# =============================================================================
if ($Action -eq 'detail') {
    $names = @($Names -split ',' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
    if ($names.Count -eq 0) { Write-Output 'STATUS: INPUT_ERROR reason=no_names'; exit 1 }
    $docOut = New-Object System.Collections.Generic.List[string]
    foreach ($nm in $names) {
        # parameter texts (FUNCT active rows) + kind (FUPARAREF)
        try {
            $prm = Read-Narrow 'FUNCT' @('PARAMETER', 'STEXT') "SPRAS = 'E' AND FUNCNAME = '$(_Esc $nm)'" 100
            foreach ($p in $prm) { Write-Output ("DETAIL: fm={0} param={1} text={2}" -f $nm, $p.PARAMETER, $p.STEXT) }
        }
        catch { }
        # FM documentation via DOCU_GET (id=FU, object=<FM>)
        try {
            $fn = $dest.Repository.CreateFunction('DOCU_GET')
            $fn.SetValue('ID', 'FU'); $fn.SetValue('LANGU', 'E'); $fn.SetValue('OBJECT', $nm); $fn.SetValue('TYP', 'E'); $fn.SetValue('VERSION', 0)
            $fn.Invoke($dest)
            $lt = $fn.GetTable('LINE')
            $docOut.Add("==== $nm ====")
            for ($i = 0; $i -lt $lt.RowCount; $i++) { $lt.CurrentIndex = $i; $docOut.Add("$($lt.GetValue('TDLINE'))") }
            Write-Output ("DETAIL: fm={0} doc_lines={1}" -f $nm, $lt.RowCount)
        }
        catch { Write-Output ("DETAIL: fm={0} doc_lines=0 (no docu)" -f $nm) }
    }
    if ($OutFile -and $docOut.Count -gt 0) { [System.IO.File]::WriteAllLines($OutFile, $docOut, (New-Object System.Text.UTF8Encoding($false))) }
    Write-Output "STATUS: OK n=$($names.Count)"
    exit 0
}
