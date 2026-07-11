# =============================================================================
# sap_sm12_lib.ps1  -  shared helpers for /sap-sm12 (dot-sourced, not run alone)
#
# Read-only. Contains NO credentials and does NOT connect -- the caller connects
# via Connect-SapRfc (sap_rfc_lib.ps1) and passes the live destination in.
#
# The TH_* kernel FMs return their data across MORE THAN ONE table (verified live
# on S4D 2026-07-11): TH_SERVER_LIST -> LIST + LIST_IPV6; TH_USER_LIST -> LIST
# (often empty) + USRLIST (populated). Both tables of a pair carry the same key
# field (NAME / BNAME), so these helpers UNION the field across every table that
# exposes it -- picking a single table by hash order would have read the empty
# decoy and reported zero users (a false GONE in the release gate). Field/table
# discovery is metadata-driven (kernel/locale independent; no hardcoded names).
#
# Dot-sourced by references/sap_sm12_list.ps1 and references/sap_sm12_liveness.ps1
# via the %%SM12_LIB_PS1%% token.
# =============================================================================

function Read-SapFmTables {
    # Invoke $Fn on $Dest, then return @{ <tableParamName> = @{ fields=@(..);
    # rows=@( @{FIELD=value; ..} ) } } for every TABLES-direction parameter.
    # Direction is matched as a STRING ('TABLES', case-insensitive) rather than
    # the strongly-typed RfcDirection enum: the enum comparison misclassified
    # scalar INT4/BYTE params of TH_SERVER_LIST as tables and then GetTable()'d
    # them (live failure, S4D 2026-07-11). $Fn must have its IMPORTING values (if
    # any) already set by the caller.
    param($Dest, $Fn)
    $Fn.Invoke($Dest)
    $out = @{}
    $meta = $Fn.Metadata
    for ($p = 0; $p -lt $meta.ParameterCount; $p++) {
        $pm = $meta[$p]
        if ("$($pm.Direction)" -ne 'TABLES') { continue }
        $tbl = $Fn.GetTable($pm.Name)
        $lt = $tbl.Metadata.LineType
        $fields = @()
        for ($f = 0; $f -lt $lt.FieldCount; $f++) { $fields += $lt[$f].Name }
        $rows = @()
        for ($r = 0; $r -lt $tbl.RowCount; $r++) {
            $tbl.CurrentIndex = $r
            $h = @{}
            # NB: loop var must NOT be $fn -- PowerShell is case-insensitive, so
            # $fn would alias the $Fn parameter and clobber it with a field name,
            # crashing GetTable() on the next TABLES param (S4D 2026-07-11).
            foreach ($fld in $fields) { $h[$fld] = "$($tbl.GetString($fld))".Trim() }
            $rows += , $h
        }
        $out[$pm.Name] = @{ fields = $fields; rows = $rows }
    }
    return $out
}

function Get-SapFieldValues {
    # UNION of the first-matching field's non-empty, UPPER-cased, distinct values
    # across EVERY table that exposes one of $FieldCandidates. Returns
    # @{ found = <bool: any table exposed a candidate field>; values = @(..) }.
    # 'found' distinguishes "table has a schema but no users" (found=$true,
    # values empty -> a legitimate answer) from "no such field anywhere"
    # (found=$false -> the caller must fail-safe to UNVERIFIABLE).
    param($Tables, [string[]]$FieldCandidates)
    $found = $false
    $set = @{}
    foreach ($k in $Tables.Keys) {
        $fld = $null
        foreach ($fc in $FieldCandidates) { if ($Tables[$k].fields -contains $fc) { $fld = $fc; break } }
        if (-not $fld) { continue }
        $found = $true
        foreach ($row in $Tables[$k].rows) {
            $v = "$($row[$fld])".Trim()
            if ($v) { $set[$v.ToUpper()] = $true }
        }
    }
    return @{ found = $found; values = @($set.Keys) }
}

function Find-SapRichestTable {
    # The table exposing a candidate field that has the MOST rows (for display
    # only -- e.g. SERVER: lines). Returns @{ name; field; rows } or $null.
    param($Tables, [string[]]$FieldCandidates)
    $best = $null
    foreach ($k in $Tables.Keys) {
        foreach ($fc in $FieldCandidates) {
            if ($Tables[$k].fields -contains $fc) {
                if ($null -eq $best -or $Tables[$k].rows.Count -gt $best.rows.Count) {
                    $best = @{ name = $k; field = $fc; rows = $Tables[$k].rows }
                }
                break
            }
        }
    }
    return $best
}

function Get-SapRowValue {
    # First non-empty value among $Candidates for a row hashtable ('' if none).
    param($Row, [string[]]$Candidates)
    foreach ($c in $Candidates) {
        if ($Row.Contains($c) -and -not [string]::IsNullOrWhiteSpace($Row[$c])) { return $Row[$c] }
    }
    return ''
}

function Get-SapLockAgeMin {
    # Whole minutes between a SEQG3 lock timestamp (GTDATE 'yyyyMMdd' + GTTIME
    # 'HHmmss', server-local) and $ServerNow (also server-local). -1 = unknown
    # (blank/zero date or parse failure). Never throws.
    param([string]$GtDate, [string]$GtTime, [datetime]$ServerNow)
    if ([string]::IsNullOrWhiteSpace($GtDate) -or $GtDate -eq '00000000') { return -1 }
    $t = if ($GtTime -and $GtTime.Length -ge 6) { $GtTime.Substring(0, 6) } else { '000000' }
    try {
        $lt = [DateTime]::ParseExact($GtDate + $t, 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture)
        $m = [math]::Floor(($ServerNow - $lt).TotalMinutes)
        if ($m -lt 0) { return 0 }
        return [int]$m
    } catch { return -1 }
}

function Get-SapServerNow {
    # Server-local "now" = workstation UTC + RFCSI_EXPORT-RFCTZONE (offset seconds
    # from UTC). Falls back to workstation local time when RFC_SYSTEM_INFO or the
    # RFCTZONE field is unavailable (AGE is display-only, never a gate input).
    param($Dest)
    try {
        $si = $Dest.Repository.CreateFunction('RFC_SYSTEM_INFO')
        $si.Invoke($Dest)
        $tz = "$($si.GetStructure('RFCSI_EXPORT').GetValue('RFCTZONE'))".Trim()
        if ($tz -match '^-?\d+$') { return [DateTime]::UtcNow.AddSeconds([int]$tz) }
    } catch { }
    return [DateTime]::Now
}
