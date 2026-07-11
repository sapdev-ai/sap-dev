# =============================================================================
# sap_gm_diff.ps1  -  Golden-vs-current diff for /sap-golden-master (OFFLINE)
#
# Two modes:
#   line  (spool legs, or table legs with no keys): ordered diff via Compare-Object
#         -> diff.txt + diff_hunks.tsv (hunk id, change_type, line_no, text).
#   keyed (table legs with -KeyColumns, esp. large): per-row keyed diff via the
#         shared sap_keyed_diff_lib.ps1 -> keyed diff.tsv (ADDED/REMOVED/CHANGED).
#
# No SAP access. Diffs two already-normalized files.
#
# Output (stdout): DIFF: mode=<line|keyed> hunks=<n> added=<n> removed=<n> changed=<n>
#                  HUNKS_TSV: <path>   DIFF_TXT: <path>
# Exit: 0 = compared (hunks may be >0) | 2 = input error.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $GoldenFile,
    [Parameter(Mandatory)] [string] $CurrentFile,
    [Parameter(Mandatory)] [string] $OutDir,
    [string] $KeyColumns = '',
    [int]    $MaxHunks = 200,
    [int]    $MaxLines = 50000,
    [string] $SharedDir = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if ($MyInvocation.InvocationName -eq '.') { return }
foreach ($f in @($GoldenFile, $CurrentFile)) { if (-not (Test-Path $f)) { Write-Host "ERROR: not found: $f"; exit 2 } }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$hunksTsv = Join-Path $OutDir 'diff_hunks.tsv'
$diffTxt  = Join-Path $OutDir 'diff.txt'

# ---- keyed mode (tables) -------------------------------------------------
if ($KeyColumns) {
    if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
    $lib = Join-Path $SharedDir 'scripts\sap_keyed_diff_lib.ps1'
    if (Test-Path $lib) {
        . $lib
        try {
            $res = Get-SapKeyedDiff -LeftPath $GoldenFile -RightPath $CurrentFile -KeyColumns $KeyColumns
            Write-SapKeyedDiffTsv -Result $res -OutPath $hunksTsv | Out-Null
            $summary = Get-SapKeyedDiffSummaryLine -Result $res
            # parse counts from the summary line "KEYED_DIFF: added=.. removed=.. changed=.. same=.."
            $added = 0; $removed = 0; $changed = 0
            if ($summary -match 'added=(\d+)')   { $added = [int]$Matches[1] }
            if ($summary -match 'removed=(\d+)') { $removed = [int]$Matches[1] }
            if ($summary -match 'changed=(\d+)') { $changed = [int]$Matches[1] }
            $hunks = $added + $removed + $changed
            [System.IO.File]::WriteAllText($diffTxt, $summary, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host ("DIFF: mode=keyed hunks={0} added={1} removed={2} changed={3}" -f $hunks, $added, $removed, $changed)
            Write-Host "HUNKS_TSV: $hunksTsv"
            Write-Host "DIFF_TXT: $diffTxt"
            exit 0
        } catch {
            Write-Host "ERROR: keyed diff failed: $($_.Exception.Message)"; exit 2
        }
    }
    # lib missing -> fall through to line mode
}

# ---- line mode (spool, or keyless) ---------------------------------------
$golden  = [System.IO.File]::ReadAllLines($GoldenFile)
$current = [System.IO.File]::ReadAllLines($CurrentFile)

# fast path: identical
$identical = ($golden.Count -eq $current.Count)
if ($identical) { for ($i = 0; $i -lt $golden.Count; $i++) { if ($golden[$i] -ne $current[$i]) { $identical = $false; break } } }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("hunk_id`tchange_type`tline_no`ttext")
$added = 0; $removed = 0; $hunkId = 0
$diffLines = New-Object System.Collections.Generic.List[string]

if (-not $identical) {
    # index first-occurrence line numbers for best-effort line_no
    $goldIdx = @{}; for ($i = 0; $i -lt $golden.Count; $i++) { if (-not $goldIdx.ContainsKey($golden[$i])) { $goldIdx[$golden[$i]] = $i + 1 } }
    $curIdx  = @{}; for ($i = 0; $i -lt $current.Count; $i++) { if (-not $curIdx.ContainsKey($current[$i])) { $curIdx[$current[$i]] = $i + 1 } }
    $sync = [Math]::Min(20000, [Math]::Max($golden.Count, $current.Count))
    $cmp = Compare-Object -ReferenceObject $golden -DifferenceObject $current -SyncWindow $sync
    foreach ($c in $cmp) {
        if ($hunkId -ge $MaxHunks) { break }
        if ($c.SideIndicator -eq '=>') {
            $added++; $hunkId++
            $lno = if ($curIdx.ContainsKey($c.InputObject)) { $curIdx[$c.InputObject] } else { 0 }
            $txt = ("$($c.InputObject)" -replace "[`t`r`n]", ' ')
            [void]$sb.AppendLine("$hunkId`tADDED`t$lno`t$txt")
            $diffLines.Add("+ [$lno] $txt")
        } elseif ($c.SideIndicator -eq '<=') {
            $removed++; $hunkId++
            $lno = if ($goldIdx.ContainsKey($c.InputObject)) { $goldIdx[$c.InputObject] } else { 0 }
            $txt = ("$($c.InputObject)" -replace "[`t`r`n]", ' ')
            [void]$sb.AppendLine("$hunkId`tREMOVED`t$lno`t$txt")
            $diffLines.Add("- [$lno] $txt")
        }
    }
}

[System.IO.File]::WriteAllText($hunksTsv, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
[System.IO.File]::WriteAllText($diffTxt, ($diffLines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
$totalHunks = $added + $removed
Write-Host ("DIFF: mode=line hunks={0} added={1} removed={2} changed=0" -f $totalHunks, $added, $removed)
if ($totalHunks -ge $MaxHunks) { Write-Host "NOTE: hunk cap $MaxHunks reached; output truncated (treat overflow as REGRESSION)" }
Write-Host "HUNKS_TSV: $hunksTsv"
Write-Host "DIFF_TXT: $diffTxt"
exit 0
