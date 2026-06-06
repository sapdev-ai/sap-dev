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
#   %%WRAPPER_STRUCT%% default "ZCMST_RFC_PARAM"
#   %%WRAPPER_TT%%   default "ZCMCT_RFC_PARAM"
#   %%UTIL_PROGRAM%% default "ZCMRUPDATE_ADDON_TABLE"
#
# Output format (one line per artefact):
#   ARTEFACT: <NAME> | KIND: <TR|PKG|FG|FM|STRUCT|TT|PGM> | STATE: <state> | DETAIL: <free text>
#
#   <state> in ACTIVE | INACTIVE | MISSING | MODIFIABLE | RELEASED |
#             EMPTY | NON_EMPTY | NOT_CONFIGURED | ERROR
#
# Summary line (last line, parseable):
#   STATUS: ALL_OK
#   STATUS: GAPS=<N>          (N artefacts not in the expected ACTIVE/MODIFIABLE state)
#   STATUS: ERROR             (RFC connection failed; details on stderr)
#
# Exit code:
#   0 = ALL_OK
#   1 = GAPS>0                (some artefacts missing or inactive)
#   2 = RFC connection failed
# =============================================================================

. "%%RFC_LIB_PS1%%"

$tr        = "%%TR%%"
$pkg       = "%%PACKAGE%%"
$fugr      = "%%FUGR%%"
$wrapperFm = if ([string]::IsNullOrWhiteSpace("%%WRAPPER_FM%%"))     { "Z_GENERIC_RFC_WRAPPER_TBL" } else { "%%WRAPPER_FM%%" }
$structName= if ([string]::IsNullOrWhiteSpace("%%WRAPPER_STRUCT%%")) { "ZCMST_RFC_PARAM"           } else { "%%WRAPPER_STRUCT%%" }
$ttName    = if ([string]::IsNullOrWhiteSpace("%%WRAPPER_TT%%"))     { "ZCMCT_RFC_PARAM"           } else { "%%WRAPPER_TT%%" }
$utilPgm   = if ([string]::IsNullOrWhiteSpace("%%UTIL_PROGRAM%%"))   { "ZCMRUPDATE_ADDON_TABLE"    } else { "%%UTIL_PROGRAM%%" }

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

Disconnect-SapRfc

if ($gaps -eq 0) {
    Write-Host "STATUS: ALL_OK"
    exit 0
} else {
    Write-Host ("STATUS: GAPS=" + $gaps)
    exit 1
}
