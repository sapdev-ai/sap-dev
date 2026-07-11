# =============================================================================
# sap_config_compare_diff.ps1  -  offline keyed diff for /sap-config-compare
#
# Dot-sources the ONE shared keyed-diff engine (sap_keyed_diff_lib.ps1) to join
# left.tsv / right.tsv on the key columns declared in meta.json and classify every
# key. Re-labels the shared engine's ADDED/REMOVED (snapshot vocabulary) into the
# cross-system LEFT_ONLY / RIGHT_ONLY vocabulary and writes diff.tsv. Pure-local,
# no SAP. Verdict is gap-aware: any excluded column / scope note / structural drift
# / row cap degrades a clean IDENTICAL to *_WITH_GAPS (never a false clean).
#
#   -LeftTsv <p> -RightTsv <p> -MetaJson <p> -OutDir <dir>
#
# stdout:
#   DIFF: left_only=<n> right_only=<n> changed=<n> identical=<n> gaps=<k>
#   VERDICT: IDENTICAL | DIFFERENT | IDENTICAL_WITH_GAPS | DIFFERENT_WITH_GAPS
#   STATUS: OK | DIFF_ERROR <detail>
# Exit: 0 OK | 2 error.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $LeftTsv,
    [Parameter(Mandatory)][string] $RightTsv,
    [Parameter(Mandatory)][string] $MetaJson,
    [Parameter(Mandatory)][string] $OutDir,
    [string] $SharedDir = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
. (Join-Path (Join-Path $SharedDir 'scripts') 'sap_keyed_diff_lib.ps1')

$RS = [char]0x241E
function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }

if ($MyInvocation.InvocationName -eq '.') { return }

try {
    if (-not (Test-Path $LeftTsv) -or -not (Test-Path $RightTsv) -or -not (Test-Path $MetaJson)) {
        Write-Host 'STATUS: DIFF_ERROR missing_input'; exit 2
    }
    $meta = Get-Content -Raw -Encoding UTF8 $MetaJson | ConvertFrom-Json
    $keys = @($meta.key_columns)
    if (-not $keys.Count) { Write-Host 'STATUS: DIFF_ERROR no_key_columns'; exit 2 }

    $res = Get-SapKeyedDiff -LeftPath $LeftTsv -RightPath $RightTsv -KeyColumns $keys
    $cmp = @($res.compared_cols)

    $lines = @("row_class`tkey`tchanged_columns`tdetail")
    foreach ($r in $res.removed) {   # in LEFT only
        $det = (@($cmp | ForEach-Object { "$_=$(San $r.row[$_])" }) -join '; ')
        $lines += ("LEFT_ONLY`t{0}`t`t{1}" -f ($r.key -replace $RS,' / '),$det)
    }
    foreach ($a in $res.added) {     # in RIGHT only
        $det = (@($cmp | ForEach-Object { "$_=$(San $a.row[$_])" }) -join '; ')
        $lines += ("RIGHT_ONLY`t{0}`t`t{1}" -f ($a.key -replace $RS,' / '),$det)
    }
    foreach ($c in $res.changed) {
        $cols = (@($c.diffs | ForEach-Object { $_.column }) -join ',')
        $det  = (@($c.diffs | ForEach-Object { "$($_.column): [$(San $_.left)] -> [$(San $_.right)]" }) -join '; ')
        $lines += ("CHANGED`t{0}`t{1}`t{2}" -f ($c.key -replace $RS,' / '),$cols,$det)
    }
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'diff.tsv'), (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))

    # gap count: excluded cols + one-sided cols + scope notes + cap
    $gaps = 0
    if ($meta.excluded_columns)   { $gaps += @($meta.excluded_columns).Count }
    if ($meta.only_left_columns)  { $gaps += @($meta.only_left_columns).Count }
    if ($meta.only_right_columns) { $gaps += @($meta.only_right_columns).Count }
    if ($meta.scope_notes)        { $gaps += @($meta.scope_notes).Count }
    if ($meta.capped -eq $true)   { $gaps += 1 }

    $nDiff = $res.removed.Count + $res.added.Count + $res.changed.Count
    $base = if ($nDiff -eq 0) { 'IDENTICAL' } else { 'DIFFERENT' }
    $verdict = if ($gaps -gt 0) { "${base}_WITH_GAPS" } else { $base }

    Write-Host (Get-SapKeyedDiffSummaryLine -Result $res)
    Write-Host ("DIFF: left_only={0} right_only={1} changed={2} identical={3} gaps={4}" -f $res.removed.Count,$res.added.Count,$res.changed.Count,$res.same_count,$gaps)
    Write-Host ("VERDICT: {0}" -f $verdict)
    Write-Host 'STATUS: OK'
    exit 0
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: DIFF_ERROR'; exit 2
}
