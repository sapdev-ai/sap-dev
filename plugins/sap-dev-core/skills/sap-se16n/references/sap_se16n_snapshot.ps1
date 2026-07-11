# =============================================================================
# sap_se16n_snapshot.ps1  -  /sap-se16n snapshot save / diff / list (pure-local)
#
# A table-state assertion primitive built on /sap-se16n's own TSV export. No SAP /
# no RFC of its own -- `save` just captures a download the SKILL already produced;
# `diff` and `list` are entirely local. The row-diff is delegated to the ONE
# suite-wide engine, sap_keyed_diff_lib.ps1 (a row differing only in a declared
# volatile column is SAME, not CHANGED). Snapshots live under
# {artifact_dir}\snapshots\<name>\ as data.tsv + meta.json.
#
#   save  -Name <n> -DataTsv <se16n.txt> -Table T [-Filters ..] -KeyColumns k1,k2
#         [-IgnoreColumns v1,v2] [-Sid ..] [-Client ..]
#   diff  -Left <a> -Right <b> [-KeyColumns ..] [-IgnoreColumns ..] -KeyedDiffLib <path>
#   list
#
# Params: -Action save|diff|list -SnapshotRoot <dir> [above per-action] [-Today yyyyMMdd]
# =============================================================================
param(
    [Parameter(Mandatory = $true)][ValidateSet('save', 'diff', 'list')][string]$Action,
    [Parameter(Mandatory = $true)][string]$SnapshotRoot,
    [string]$Name = '', [string]$Left = '', [string]$Right = '',
    [string]$DataTsv = '', [string]$Table = '', [string]$Filters = '',
    [string]$KeyColumns = '', [string]$IgnoreColumns = '',
    [string]$Sid = '', [string]$Client = '', [string]$KeyedDiffLib = '', [string]$Today = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Today) { $Today = (Get-Date).ToString('yyyyMMdd_HHmmss') }
function _Meta([string]$dir) { $m = Join-Path $dir 'meta.json'; if (Test-Path $m) { return ([IO.File]::ReadAllText($m, [Text.Encoding]::UTF8) | ConvertFrom-Json) } return $null }
function _Split([string]$s) { if (-not $s) { return @() } return @($s -split '\s*,\s*' | Where-Object { $_ }) }

switch ($Action) {
    'save' {
        if (-not $Name) { Write-Host 'STATUS: ERROR save needs -Name'; exit 2 }
        if (-not (Test-Path $DataTsv)) { Write-Host "STATUS: ERROR data tsv not found: $DataTsv"; exit 2 }
        $first = ''
        try { $first = @([IO.File]::ReadAllLines($DataTsv, [Text.Encoding]::UTF8))[0] } catch { }
        if ($first -like 'QUERY_FAILED*' -or $first -like 'NO_DATA*') {
            Write-Host "STATUS: ERROR refusing to snapshot a non-result export ($first) -- fix the query first"; exit 2
        }
        $dir = Join-Path $SnapshotRoot $Name
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $dst = Join-Path $dir 'data.tsv'
        Copy-Item -LiteralPath $DataTsv -Destination $dst -Force
        $rows = @([IO.File]::ReadAllLines($dst, [Text.Encoding]::UTF8)).Count - 1
        if ($rows -lt 0) { $rows = 0 }
        $meta = [ordered]@{ schema = 'sapdev.se16n_snapshot/1'; name = $Name; table = $Table.ToUpper()
            filters = $Filters; key_columns = @(_Split $KeyColumns); ignore_columns = @(_Split $IgnoreColumns)
            sid = $Sid; client = $Client; saved_at = $Today; rows = $rows
        }
        [IO.File]::WriteAllText((Join-Path $dir 'meta.json'), ($meta | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        Write-Host "STATUS: SAVED name=$Name table=$($meta.table) rows=$rows keys=[$KeyColumns] path=$dir"
    }
    'list' {
        if (-not (Test-Path $SnapshotRoot)) { Write-Host 'STATUS: OK snapshots=0'; exit 0 }
        $n = 0
        foreach ($d in @(Get-ChildItem -LiteralPath $SnapshotRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $m = _Meta $d.FullName; if (-not $m) { continue }
            $n++
            Write-Host ("SNAPSHOT: name={0} table={1} rows={2} keys=[{3}] sid={4} client={5} saved_at={6}" -f `
                    $m.name, $m.table, $m.rows, (@($m.key_columns) -join ','), $m.sid, $m.client, $m.saved_at)
        }
        Write-Host "STATUS: OK snapshots=$n root=$SnapshotRoot"
    }
    'diff' {
        if (-not $Left -or -not $Right) { Write-Host 'STATUS: ERROR diff needs -Left and -Right'; exit 2 }
        $ld = Join-Path $SnapshotRoot $Left; $rd = Join-Path $SnapshotRoot $Right
        $lm = _Meta $ld; $rm = _Meta $rd
        if (-not $lm) { Write-Host "STATUS: ERROR snapshot not found: $Left"; exit 2 }
        if (-not $rm) { Write-Host "STATUS: ERROR snapshot not found: $Right"; exit 2 }
        if ($lm.table -and $rm.table -and ($lm.table -ne $rm.table)) {
            Write-Host "STATUS: ERROR table mismatch: $Left=$($lm.table) vs $Right=$($rm.table) -- refusing cross-table diff"; exit 2
        }
        # keys/ignore: explicit args win, else the snapshots' declared metadata (must agree)
        $keys = _Split $KeyColumns
        if (-not $keys.Count) { $keys = @($lm.key_columns) }
        if (-not $keys.Count) { Write-Host "STATUS: ERROR no key columns (pass --keys or save with -KeyColumns)"; exit 2 }
        $ignore = _Split $IgnoreColumns
        if (-not $ignore.Count -and $lm.ignore_columns) { $ignore = @($lm.ignore_columns) }
        if (-not $KeyedDiffLib -or -not (Test-Path $KeyedDiffLib)) { Write-Host "STATUS: ERROR keyed-diff lib not found: $KeyedDiffLib"; exit 2 }
        . $KeyedDiffLib
        $res = Get-SapKeyedDiff -LeftPath (Join-Path $ld 'data.tsv') -RightPath (Join-Path $rd 'data.tsv') -KeyColumns $keys -IgnoreColumns $ignore
        $out = Join-Path $SnapshotRoot ("diff_{0}_vs_{1}.tsv" -f $Left, $Right)
        $w = Write-SapKeyedDiffTsv -Result $res -OutPath $out
        Write-Host ("DIFF: left={0} right={1} keys=[{2}] ignore=[{3}]" -f $Left, $Right, ($keys -join ','), ($ignore -join ','))
        Write-Host (Get-SapKeyedDiffSummaryLine $res)
        Write-Host "STATUS: OK diff_rows=$($w.rows) out=$out"
    }
}
