# =============================================================================
# sap_keyed_diff_lib.ps1  -  the ONE keyed row-diff engine for the sap-dev suite
#
# Pure-local (no SAP / no RFC). Joins two TSV extracts on declared KEY columns and
# classifies every key as ADDED / REMOVED / CHANGED / SAME, ignoring a declared
# set of VOLATILE columns (timestamps, counters) in the change comparison. Shared
# by /sap-config-compare (cross-system customizing diff), /sap-se16n snapshot diff
# (T1-E), and /sap-compare --table-content (T2) so there is exactly one diff
# semantics suite-wide.
#
# Dot-source via the %%KEYED_DIFF_LIB_PS1%% token, then:
#   $res = Get-SapKeyedDiff -LeftPath a.tsv -RightPath b.tsv -KeyColumns MANDT,BUKRS `
#                           [-IgnoreColumns AEDAT,AEZEIT] [-Delimiter "`t"]
#   Write-SapKeyedDiffTsv -Result $res -OutPath diff.tsv
#
# TSV shape: first line = tab-separated header; UTF-8 (BOM tolerated). Only the
# columns COMMON to both sides are compared (schema drift is reported, never a
# silent pass); key columns must exist on both sides or the call throws.
# =============================================================================

function _Read-SapTsvTable {
    param([string]$Path, [string]$Delimiter = "`t")
    if (-not (Test-Path $Path)) { throw "keyed-diff: file not found: $Path" }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $text = $text.TrimStart([char]0xFEFF)                      # tolerate a UTF-8 BOM
    $lines = $text -split "`r`n|`n|`r"
    # drop a single trailing empty line from the final newline
    while ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)]; if ($lines.Count -eq 0) { break } }
    if ($lines.Count -eq 0) { return @{ header = @(); rows = @() } }
    $header = @($lines[0] -split ([Regex]::Escape($Delimiter)))
    $rows = @()
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '') { continue }
        $parts = $lines[$i] -split ([Regex]::Escape($Delimiter))
        $row = [ordered]@{}
        for ($k = 0; $k -lt $header.Count; $k++) { $row[$header[$k]] = if ($k -lt $parts.Count) { $parts[$k] } else { '' } }
        $rows += , $row
    }
    return @{ header = $header; rows = $rows }
}

function Get-SapKeyedDiff {
    param(
        [Parameter(Mandatory = $true)][string]$LeftPath,
        [Parameter(Mandatory = $true)][string]$RightPath,
        [Parameter(Mandatory = $true)][string[]]$KeyColumns,
        [string[]]$IgnoreColumns = @(),
        [string]$Delimiter = "`t"
    )
    $L = _Read-SapTsvTable -Path $LeftPath -Delimiter $Delimiter
    $R = _Read-SapTsvTable -Path $RightPath -Delimiter $Delimiter

    # key columns must exist on BOTH sides
    $missingL = @($KeyColumns | Where-Object { $L.header -notcontains $_ })
    $missingR = @($KeyColumns | Where-Object { $R.header -notcontains $_ })
    if ($missingL.Count -or $missingR.Count) {
        throw ("keyed-diff: key column(s) missing -- left:[{0}] right:[{1}]" -f ($missingL -join ','), ($missingR -join ','))
    }

    # compared columns = common, minus key, minus ignore. Report schema drift.
    $common = @($L.header | Where-Object { $R.header -contains $_ })
    $onlyLeft = @($L.header | Where-Object { $R.header -notcontains $_ })
    $onlyRight = @($R.header | Where-Object { $L.header -notcontains $_ })
    $cmpCols = @($common | Where-Object { $KeyColumns -notcontains $_ -and $IgnoreColumns -notcontains $_ })

    function _Key($row) { ($KeyColumns | ForEach-Object { "$($row[$_])" }) -join "`u{241E}" }  # RS char, unlikely in data
    $lMap = @{}; $lDup = 0
    foreach ($row in $L.rows) { $k = _Key $row; if ($lMap.ContainsKey($k)) { $lDup++ }; $lMap[$k] = $row }
    $rMap = @{}; $rDup = 0
    foreach ($row in $R.rows) { $k = _Key $row; if ($rMap.ContainsKey($k)) { $rDup++ }; $rMap[$k] = $row }

    $added = @(); $removed = @(); $changed = @(); $same = 0
    foreach ($k in $rMap.Keys) { if (-not $lMap.ContainsKey($k)) { $added += , @{ key = $k; row = $rMap[$k] } } }
    foreach ($k in $lMap.Keys) {
        if (-not $rMap.ContainsKey($k)) { $removed += , @{ key = $k; row = $lMap[$k] }; continue }
        $lr = $lMap[$k]; $rr = $rMap[$k]; $diffs = @()
        foreach ($c in $cmpCols) {
            $lv = "$($lr[$c])"; $rv = "$($rr[$c])"
            if ($lv -cne $rv) { $diffs += , @{ column = $c; left = $lv; right = $rv } }
        }
        if ($diffs.Count) { $changed += , @{ key = $k; diffs = $diffs } } else { $same++ }
    }

    return [ordered]@{
        key_columns    = @($KeyColumns)
        ignore_columns = @($IgnoreColumns)
        compared_cols  = $cmpCols
        only_left_cols = $onlyLeft
        only_right_cols = $onlyRight
        left_count     = $L.rows.Count
        right_count    = $R.rows.Count
        left_dup_keys  = $lDup
        right_dup_keys = $rDup
        added          = $added
        removed        = $removed
        changed        = $changed
        same_count     = $same
    }
}

function Write-SapKeyedDiffTsv {
    param([Parameter(Mandatory = $true)]$Result, [Parameter(Mandatory = $true)][string]$OutPath)
    $keyDisp = ($Result.key_columns -join '+')
    $lines = @("row_class`tkey`tchanged_columns`tdetail")
    foreach ($a in $Result.added) {
        $det = (@($Result.compared_cols | ForEach-Object { "$_=$($a.row[$_])" }) -join '; ')
        $lines += ("ADDED`t{0}`t`t{1}" -f ($a.key -replace "`u{241E}", '|'), $det)
    }
    foreach ($r in $Result.removed) {
        $det = (@($Result.compared_cols | ForEach-Object { "$_=$($r.row[$_])" }) -join '; ')
        $lines += ("REMOVED`t{0}`t`t{1}" -f ($r.key -replace "`u{241E}", '|'), $det)
    }
    foreach ($c in $Result.changed) {
        $cols = (@($c.diffs | ForEach-Object { $_.column }) -join ',')
        $det = (@($c.diffs | ForEach-Object { "$($_.column): [$($_.left)] -> [$($_.right)]" }) -join '; ')
        $lines += ("CHANGED`t{0}`t{1}`t{2}" -f ($c.key -replace "`u{241E}", '|'), $cols, $det)
    }
    $dir = Split-Path -Parent $OutPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($OutPath, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($true)))  # BOM for Excel
    return @{ path = $OutPath; header_key = $keyDisp; rows = ($Result.added.Count + $Result.removed.Count + $Result.changed.Count) }
}

function Get-SapKeyedDiffSummaryLine {
    param([Parameter(Mandatory = $true)]$Result)
    $drift = ''
    if ($Result.only_left_cols.Count -or $Result.only_right_cols.Count) {
        $drift = " schema_drift=left_only:[{0}]|right_only:[{1}]" -f ($Result.only_left_cols -join ','), ($Result.only_right_cols -join ',')
    }
    $dup = ''
    if ($Result.left_dup_keys -or $Result.right_dup_keys) { $dup = " dup_keys=L:$($Result.left_dup_keys)/R:$($Result.right_dup_keys)" }
    return ("KEYED_DIFF: added={0} removed={1} changed={2} same={3} left={4} right={5}{6}{7}" -f `
            $Result.added.Count, $Result.removed.Count, $Result.changed.Count, $Result.same_count, `
            $Result.left_count, $Result.right_count, $drift, $dup)
}
