# =============================================================================
# sap_dev_artefacts.ps1  -  Shared status checker for sap-dev-init artefacts
#
# Queries the SAP system for every artefact `/sap-dev-init` is responsible
# for and emits one parseable line per artefact. Used by:
#
#   /sap-dev-status   -- read-only report ("is my dev env healthy?")
#   /sap-dev-clean    -- pre-flight before destructive cleanup ("what's
#                       actually here?")
#   /sap-dev-init     -- idempotency check before re-creating
#
# Tokens replaced at run time:
#   %%SAP_SERVER%%   %%SAP_SYSNR%%   %%SAP_CLIENT%%
#   %%SAP_USER%%     %%SAP_PASSWORD%%   %%SAP_LANGUAGE%%
#   %%RFC_LIB_PS1%%  absolute path to sap_rfc_lib.ps1
#   %%TR%%           sap_dev_transport_request (or empty if blank)
#   %%PACKAGE%%      sap_dev_package
#   %%FUGR%%         sap_dev_function_group
#   %%WRAPPER_FM%%   default "Z_GENERIC_RFC_WRAPPER_TBL"
#   %%WRAPPER_DOMAIN%% default "ZCMD_RFCVAL"
#   %%WRAPPER_DTEL%% default "ZCMDE_RFCVAL"
#   %%WRAPPER_STRUCT%% default "ZCMST_RFC_PARAM"
#   %%WRAPPER_TT%%   default "ZCMCT_RFC_PARAM"
#   %%UTIL_PROGRAM%% default "ZCMRUPDATE_ADDON_TABLE"
#   %%CLASS_INSTALLER_FM%% default "Z_CLASS_SOURCE_INSTALL" (OPTIONAL -- SE24 Step 4.7;
#                   absence is informational, never a gap)
#
# Output format (one line per artefact):
#   ARTEFACT: <NAME> | KIND: <TR|PKG|FG|FM|DOMA|DTEL|STRUCT|TT|PGM> | STATE: <state> | DETAIL: <free text>
#
#   <state> in ACTIVE | INACTIVE | MISSING | MODIFIABLE | RELEASED |
#             EMPTY | NON_EMPTY | NOT_CONFIGURED | ERROR
#
# Anchor-validation lines (emitted when the wrapper FM exists -- it is the
# immovable anchor of the dev-init toolset):
#   ANCHOR: wrapper_fm=<FM> | package=<actual> | fugr=<actual>
#       Where the toolset ACTUALLY lives (FM -> TFDIR.PNAME -> FG -> TADIR pkg).
#       This is the source of truth; the configured sap_dev_* are only hints.
#   CONFIG_MISMATCH: <key> | configured=<X> | anchor=<Y> | <why>
#       A configured sap_dev_package / sap_dev_function_group that is non-blank
#       but DIFFERENT from the anchor. DANGEROUS -- a destructive clean/reset
#       would aim at <X> (the wrong objects). Callers MUST refuse and surface
#       <Y> as the correction.
#   CONFIG_HINT: <key> is blank | anchor=<Y>
#       Configured value is blank; clean safely skips it, but it should be <Y>.
#
# Summary lines (last lines, parseable):
#   CONFIG: OK  |  CONFIG: MISMATCH=<M>     (always emitted when the FM exists)
#   STATUS: ALL_OK
#   STATUS: GAPS=<N>          (N artefacts not in the expected ACTIVE/MODIFIABLE state)
#   STATUS: CONFIG_MISMATCH   (>=1 configured pointer disagrees with the anchor)
#   STATUS: ERROR             (RFC connection failed; details on stderr)
#
# Exit code:
#   0 = ALL_OK
#   1 = GAPS>0                (some artefacts missing or inactive)
#   2 = RFC connection failed
#   3 = CONFIG_MISMATCH       (config points at the wrong package/FG -- refuse to clean)
# =============================================================================

. "%%RFC_LIB_PS1%%"

$tr        = "%%TR%%"
$pkg       = "%%PACKAGE%%"
$fugr      = "%%FUGR%%"
$wrapperFm = if ([string]::IsNullOrWhiteSpace("%%WRAPPER_FM%%"))     { "Z_GENERIC_RFC_WRAPPER_TBL" } else { "%%WRAPPER_FM%%" }
$structName= if ([string]::IsNullOrWhiteSpace("%%WRAPPER_STRUCT%%")) { "ZCMST_RFC_PARAM"           } else { "%%WRAPPER_STRUCT%%" }
$ttName    = if ([string]::IsNullOrWhiteSpace("%%WRAPPER_TT%%"))     { "ZCMCT_RFC_PARAM"           } else { "%%WRAPPER_TT%%" }
$utilPgm   = if ([string]::IsNullOrWhiteSpace("%%UTIL_PROGRAM%%"))   { "ZCMRUPDATE_ADDON_TABLE"    } else { "%%UTIL_PROGRAM%%" }
# Wrapper payload domain + data element (single-source DDIC). Default to the
# shipped names; also fall back to the default when the token is left
# unsubstituted, so existing callers need no change to pick these up.
$domName   = if ("%%WRAPPER_DOMAIN%%" -like "*WRAPPER_DOMAIN*" -or [string]::IsNullOrWhiteSpace("%%WRAPPER_DOMAIN%%")) { "ZCMD_RFCVAL"  } else { "%%WRAPPER_DOMAIN%%" }
$dtelName  = if ("%%WRAPPER_DTEL%%"   -like "*WRAPPER_DTEL*"   -or [string]::IsNullOrWhiteSpace("%%WRAPPER_DTEL%%"))   { "ZCMDE_RFCVAL" } else { "%%WRAPPER_DTEL%%" }

$g_dest = Connect-SapRfc -Server   "%%SAP_SERVER%%"   `
                         -Sysnr    "%%SAP_SYSNR%%"    `
                         -Client   "%%SAP_CLIENT%%"   `
                         -User     "%%SAP_USER%%"     `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "DEV_ARTEFACTS"
if (-not $g_dest) {
    Write-Host "STATUS: ERROR"
    exit 2
}

$gaps = 0

# Anchor-validation state. The wrapper FM is the immovable anchor of the
# dev-init toolset: where it actually lives (its function group, and that FG's
# package) is the source of truth, while the configured sap_dev_package /
# sap_dev_function_group are only hints. If they disagree, a destructive
# /sap-dev-clean would aim at the wrong objects -- so we resolve the anchor
# (section 8) and cross-check.
$g_wrapperExists = $false
$g_wrapperFg     = ""
$mismatch        = 0

function Emit($name, $kind, $state, $detail) {
    Write-Host ("ARTEFACT: {0} | KIND: {1} | STATE: {2} | DETAIL: {3}" -f $name, $kind, $state, $detail)
}

function Q-RfcReadTable($table, $where, $cols) {
    $fn = $g_dest.Repository.CreateFunction("RFC_READ_TABLE")
    $fn.SetValue("QUERY_TABLE", $table)
    $fn.SetValue("DELIMITER", "|")
    if ($where) { Add-RfcOption $fn $where }
    foreach ($c in $cols) { Add-RfcField $fn $c }
    try {
        $fn.Invoke($g_dest)
    } catch {
        return $null
    }
    $data = $fn.GetTable("DATA")
    $rows = @()
    for ($i = 0; $i -lt $data.RowCount; $i++) {
        $data.CurrentIndex = $i
        $rows += ,$data.GetString("WA")
    }
    # Comma operator forces array return semantics. Without it, PowerShell
    # unrolls an empty `@()` to `$null` on return, making 0-row RFC results
    # indistinguishable from RFC failures (catch returns $null explicitly).
    # Callers rely on `$null -eq $rows` -> ERROR vs `$rows.Count -eq 0` ->
    # MISSING. The wrapper is unrolled by the caller's assignment so a
    # non-empty array still arrives intact.
    return ,$rows
}

# ---------------------------------------------------------------------------
# 1. Transport request -- E070
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($tr)) {
    Emit "(none)" "TR" "NOT_CONFIGURED" "sap_dev_transport_request is blank"
    $gaps++
} else {
    $rows = Q-RfcReadTable "E070" "TRKORR = '$tr'" @("TRKORR","TRSTATUS","STRKORR")
    if ($null -eq $rows) {
        Emit $tr "TR" "ERROR" "RFC_READ_TABLE on E070 failed"
        $gaps++
    } elseif ($rows.Count -eq 0) {
        Emit $tr "TR" "MISSING" "no E070 row"
        $gaps++
    } else {
        $cols = $rows[0].Split('|') | ForEach-Object { $_.Trim() }
        # TRSTATUS = D / L = modifiable, R / N = released
        $trStatus = $cols[1]
        if ($trStatus -in @("D","L")) {
            Emit $tr "TR" "MODIFIABLE" "TRSTATUS=$trStatus"
        } elseif ($trStatus -in @("R","N","O")) {
            Emit $tr "TR" "RELEASED"   "TRSTATUS=$trStatus (cannot accept new objects)"
            $gaps++
        } else {
            Emit $tr "TR" "ERROR"      "Unknown TRSTATUS=$trStatus"
            $gaps++
        }
    }
}

# ---------------------------------------------------------------------------
# 2. Package -- TDEVC
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($pkg)) {
    Emit "(none)" "PKG" "NOT_CONFIGURED" "sap_dev_package is blank"
    $gaps++
} else {
    $rows = Q-RfcReadTable "TDEVC" "DEVCLASS = '$pkg'" @("DEVCLASS","PARENTCL")
    if ($null -eq $rows) {
        Emit $pkg "PKG" "ERROR" "RFC_READ_TABLE on TDEVC failed"
        $gaps++
    } elseif ($rows.Count -eq 0) {
        Emit $pkg "PKG" "MISSING" "no TDEVC row"
        $gaps++
    } else {
        # Count direct TADIR children to see if it's empty.
        $kids = Q-RfcReadTable "TADIR" "DEVCLASS = '$pkg'" @("OBJECT","OBJ_NAME")
        if ($null -ne $kids -and $kids.Count -eq 0) {
            Emit $pkg "PKG" "EMPTY" "TDEVC ok, no TADIR children"
        } else {
            $kidCount = if ($null -eq $kids) { "?" } else { $kids.Count }
            Emit $pkg "PKG" "NON_EMPTY" "TDEVC ok, TADIR children=$kidCount"
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Function group -- TLIBG + PROGDIR for SAPL<FG>
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($fugr)) {
    Emit "(none)" "FG" "NOT_CONFIGURED" "sap_dev_function_group is blank"
    $gaps++
} else {
    $rows = Q-RfcReadTable "TLIBG" "AREA = '$fugr'" @("AREA")
    if ($null -eq $rows) {
        Emit $fugr "FG" "ERROR" "RFC_READ_TABLE on TLIBG failed"
        $gaps++
    } elseif ($rows.Count -eq 0) {
        Emit $fugr "FG" "MISSING" "no TLIBG row"
        $gaps++
    } else {
        $saplName = "SAPL$fugr"
        $progRows = Q-RfcReadTable "PROGDIR" "NAME = '$saplName' AND STATE = 'A'" @("NAME","STATE")
        if ($null -ne $progRows -and $progRows.Count -ge 1) {
            Emit $fugr "FG" "ACTIVE" "TLIBG ok, PROGDIR.STATE=A for $saplName"
        } else {
            Emit $fugr "FG" "INACTIVE" "TLIBG ok, but no active PROGDIR row for $saplName"
            $gaps++
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Wrapper FM -- TFDIR (existence + Remote-Enabled flag FMODE='R')
# ---------------------------------------------------------------------------
# FMODE = 'R' means Remote-Enabled Module -- mandatory for this wrapper
# because the only consumer is NCo 3.1 (PowerShell, sap_rfc_wrapper_fm.ps1).
# An FM created via SE37 starts as 'Regular Function Module' (FMODE blank)
# and stays that way unless /sap-dev-init Step 7b runs /sap-se37 change_attrs
# PROCESSING_TYPE=REMOTE. If we see FMODE != 'R', surface it as a gap so a
# re-run of /sap-dev-init / /sap-dev-status catches the bad state.
$rows = Q-RfcReadTable "TFDIR" "FUNCNAME = '$wrapperFm'" @("FUNCNAME","PNAME","FMODE")
if ($null -eq $rows) {
    Emit $wrapperFm "FM" "ERROR" "RFC_READ_TABLE on TFDIR failed"
    $gaps++
} elseif ($rows.Count -eq 0) {
    Emit $wrapperFm "FM" "MISSING" "no TFDIR row -- run /sap-dev-init"
    $gaps++
} else {
    # Row format from RFC_READ_TABLE with DELIMITER='|':
    #   "FUNCNAME |PNAME    |FMODE"  (trailing-padded fields)
    # The FM exists -> it anchors the toolset. PNAME is the FG main program
    # 'SAPL<FG>'; strip the prefix to get the function group (section 8 then
    # resolves that FG's package via TADIR).
    $g_wrapperExists = $true
    $wpname = ($rows[0] -split '\|')[1].Trim()
    if ($wpname -like 'SAPL*') { $g_wrapperFg = $wpname.Substring(4) }
    $fmodeOk = $false
    foreach ($r in $rows) {
        $parts = $r -split '\|'
        if ($parts.Count -ge 3 -and $parts[2].Trim() -eq 'R') { $fmodeOk = $true; break }
    }
    if ($fmodeOk) {
        Emit $wrapperFm "FM" "ACTIVE" "TFDIR ok, FMODE=R (Remote-Enabled)"
    } else {
        Emit $wrapperFm "FM" "INACTIVE" "TFDIR ok but FMODE != 'R' (Regular FM) -- run /sap-dev-init Step 7b to set Remote-Enabled"
        $gaps++
    }
}

# ---------------------------------------------------------------------------
# 4a. Wrapper payload domain -- DD01L AS4LOCAL='A'
# ---------------------------------------------------------------------------
$rows = Q-RfcReadTable "DD01L" "DOMNAME = '$domName' AND AS4LOCAL = 'A'" @("DOMNAME")
if ($null -eq $rows) {
    Emit $domName "DOMA" "ERROR" "RFC_READ_TABLE on DD01L failed"
    $gaps++
} elseif ($rows.Count -eq 0) {
    Emit $domName "DOMA" "MISSING" "no active DD01L row -- run /sap-dev-init"
    $gaps++
} else {
    Emit $domName "DOMA" "ACTIVE" "DD01L AS4LOCAL=A"
}

# ---------------------------------------------------------------------------
# 4b. Wrapper payload data element -- DD04L AS4LOCAL='A'
# ---------------------------------------------------------------------------
$rows = Q-RfcReadTable "DD04L" "ROLLNAME = '$dtelName' AND AS4LOCAL = 'A'" @("ROLLNAME")
if ($null -eq $rows) {
    Emit $dtelName "DTEL" "ERROR" "RFC_READ_TABLE on DD04L failed"
    $gaps++
} elseif ($rows.Count -eq 0) {
    Emit $dtelName "DTEL" "MISSING" "no active DD04L row -- run /sap-dev-init"
    $gaps++
} else {
    Emit $dtelName "DTEL" "ACTIVE" "DD04L AS4LOCAL=A"
}

# ---------------------------------------------------------------------------
# 5. Wrapper structure -- DD02L AS4LOCAL='A'
# ---------------------------------------------------------------------------
$rows = Q-RfcReadTable "DD02L" "TABNAME = '$structName' AND AS4LOCAL = 'A'" @("TABNAME","TABCLASS")
if ($null -eq $rows) {
    Emit $structName "STRUCT" "ERROR" "RFC_READ_TABLE on DD02L failed"
    $gaps++
} elseif ($rows.Count -eq 0) {
    Emit $structName "STRUCT" "MISSING" "no active DD02L row -- run /sap-dev-init"
    $gaps++
} else {
    Emit $structName "STRUCT" "ACTIVE" "DD02L AS4LOCAL=A"
}

# ---------------------------------------------------------------------------
# 6. Wrapper table type -- DD40L AS4LOCAL='A'
# ---------------------------------------------------------------------------
$rows = Q-RfcReadTable "DD40L" "TYPENAME = '$ttName' AND AS4LOCAL = 'A'" @("TYPENAME")
if ($null -eq $rows) {
    Emit $ttName "TT" "ERROR" "RFC_READ_TABLE on DD40L failed"
    $gaps++
} elseif ($rows.Count -eq 0) {
    Emit $ttName "TT" "MISSING" "no active DD40L row -- run /sap-dev-init"
    $gaps++
} else {
    Emit $ttName "TT" "ACTIVE" "DD40L AS4LOCAL=A"
}

# ---------------------------------------------------------------------------
# 7. Utility program -- PROGDIR STATE='A'
# ---------------------------------------------------------------------------
$rows = Q-RfcReadTable "PROGDIR" "NAME = '$utilPgm' AND STATE = 'A'" @("NAME","STATE")
if ($null -eq $rows) {
    Emit $utilPgm "PGM" "ERROR" "RFC_READ_TABLE on PROGDIR failed"
    $gaps++
} elseif ($rows.Count -eq 0) {
    Emit $utilPgm "PGM" "MISSING" "no active PROGDIR row -- run /sap-dev-init"
    $gaps++
} else {
    Emit $utilPgm "PGM" "ACTIVE" "PROGDIR.STATE=A"
}

# ---------------------------------------------------------------------------
# 7b. SE24 RFC class-source installer -- Z_CLASS_SOURCE_INSTALL (OPTIONAL)
# ---------------------------------------------------------------------------
# Backs /sap-se24's Step 4.7 RFC deploy fallback (headless class-source install).
# It is OPTIONAL, unlike everything above: the /sap-se24 caller self-heals it on
# first RFC use, and it needs the OO source API (CL_OO_FACTORY, NW 7.31 EhP6+) so
# it legitimately does not exist on genuinely old stacks. Therefore its absence is
# reported informationally and NEVER increments $gaps (must not flip a healthy env
# to STATUS: GAPS). Token falls back to the default when left unsubstituted.
$classInstallerFm = if ("%%CLASS_INSTALLER_FM%%" -like "*CLASS_INSTALLER_FM*" -or [string]::IsNullOrWhiteSpace("%%CLASS_INSTALLER_FM%%")) { "Z_CLASS_SOURCE_INSTALL" } else { "%%CLASS_INSTALLER_FM%%" }
$rows = Q-RfcReadTable "TFDIR" "FUNCNAME = '$classInstallerFm'" @("FUNCNAME","FMODE")
if ($null -eq $rows) {
    Emit $classInstallerFm "FM" "ERROR" "RFC_READ_TABLE on TFDIR failed (optional artefact)"
} elseif ($rows.Count -eq 0) {
    Emit $classInstallerFm "FM" "MISSING" "OPTIONAL -- /sap-se24 Step 4.7 self-heals it on first RFC use (not a gap)"
} else {
    $ciFmodeOk = $false
    foreach ($r in $rows) { $parts = $r -split '\|'; if ($parts.Count -ge 2 -and $parts[1].Trim() -eq 'R') { $ciFmodeOk = $true; break } }
    if ($ciFmodeOk) {
        Emit $classInstallerFm "FM" "ACTIVE" "TFDIR ok, FMODE=R (SE24 RFC installer ready)"
    } else {
        Emit $classInstallerFm "FM" "INACTIVE" "OPTIONAL -- TFDIR ok but FMODE != 'R'; re-deploy Remote-Enabled if you want the SE24 RFC fallback"
    }
}

# ---------------------------------------------------------------------------
# 8. Anchor validation -- does the configured package / FG actually host the
#    dev-init toolset?
# ---------------------------------------------------------------------------
# The wrapper FM is the anchor. Resolve its function group (captured from
# TFDIR.PNAME in section 4) and that FG's package (TADIR R3TR/FUGR), then
# cross-check the configured sap_dev_package / sap_dev_function_group:
#   * non-blank but DIFFERENT  -> CONFIG_MISMATCH (dangerous; callers refuse).
#   * blank                    -> CONFIG_HINT     (clean skips it; just incomplete).
# Only runs when the anchor FM exists -- otherwise the per-artefact MISSING
# states already say "run /sap-dev-init", and there is nothing to anchor to.
if ($g_wrapperExists -and -not [string]::IsNullOrWhiteSpace($g_wrapperFg)) {
    $anchorPkg = ""
    $tadirRows = Q-RfcReadTable "TADIR" "PGMID = 'R3TR' AND OBJECT = 'FUGR' AND OBJ_NAME = '$g_wrapperFg'" @("DEVCLASS","OBJ_NAME")
    if ($null -ne $tadirRows -and $tadirRows.Count -ge 1) {
        $anchorPkg = ($tadirRows[0] -split '\|')[0].Trim()
    }
    Write-Host ("ANCHOR: wrapper_fm={0} | package={1} | fugr={2}" -f $wrapperFm, $anchorPkg, $g_wrapperFg)

    if (-not [string]::IsNullOrWhiteSpace($anchorPkg)) {
        if ([string]::IsNullOrWhiteSpace($pkg)) {
            Write-Host ("CONFIG_HINT: sap_dev_package is blank | anchor=$anchorPkg")
        } elseif ($pkg.Trim().ToUpper() -ne $anchorPkg.ToUpper()) {
            Write-Host ("CONFIG_MISMATCH: sap_dev_package | configured=$pkg | anchor=$anchorPkg | the wrapper FM lives in $anchorPkg, not $pkg")
            $mismatch++
        }
    }

    if ([string]::IsNullOrWhiteSpace($fugr)) {
        Write-Host ("CONFIG_HINT: sap_dev_function_group is blank | anchor=$g_wrapperFg")
    } elseif ($fugr.Trim().ToUpper() -ne $g_wrapperFg.ToUpper()) {
        Write-Host ("CONFIG_MISMATCH: sap_dev_function_group | configured=$fugr | anchor=$g_wrapperFg | the wrapper FM belongs to $g_wrapperFg, not $fugr")
        $mismatch++
    }
} elseif ($g_wrapperExists) {
    Write-Host ("ANCHOR: wrapper_fm={0} | package=? | fugr=? (could not derive FG from PNAME)" -f $wrapperFm)
}

if ($g_wrapperExists) {
    if ($mismatch -gt 0) { Write-Host ("CONFIG: MISMATCH=" + $mismatch) } else { Write-Host "CONFIG: OK" }
}

Disconnect-SapRfc

# A config mismatch outranks artefact gaps: a wrong pointer makes a destructive
# clean unsafe regardless of how healthy the (mis-located) artefacts look.
if ($mismatch -gt 0) {
    Write-Host "STATUS: CONFIG_MISMATCH"
    exit 3
} elseif ($gaps -eq 0) {
    Write-Host "STATUS: ALL_OK"
    exit 0
} else {
    Write-Host ("STATUS: GAPS=" + $gaps)
    exit 1
}
