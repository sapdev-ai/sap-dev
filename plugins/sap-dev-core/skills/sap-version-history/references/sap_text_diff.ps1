# =============================================================================
# sap_text_diff.ps1  -  offline two-file LCS unified diff for /sap-version-history
#
# A positional line-level unified diff of TWO source files (version A vs B, or
# active vs a stored version). Distinct from /sap-compare's sap_compare_diff.ps1,
# which is a directory-tree SET diff (Compare-Object over paired files) -- that
# one answers "which files/lines differ across two trees", this one answers
# "what changed line-by-line between two versions of ONE object", with context
# hunks Claude can annotate. (A future consolidation could host a shared unified-
# diff engine and upgrade sap-compare onto it; kept local for now.)
#
#   -LeftFile <a> -RightFile <b> -OutFile <diff> [-LeftLabel L -RightLabel R]
#   [-Context 3]
#
# Normalizes trailing whitespace (a stored SVRS version vs an active RPY read can
# differ only in trailing blanks -- never reported as a real change). Emits the
# unified diff to -OutFile and a machine-readable summary to stdout:
#   DIFF: added=<n> removed=<n> hunks=<h>    (or  DIFF: identical)
# Guardrail: for very large pairs (LxR > 4,000,000 cells) it falls back to a
# set-diff with a FALLBACK note rather than building a huge DP table.
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$LeftFile,
    [Parameter(Mandatory = $true)][string]$RightFile,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$LeftLabel = 'LEFT',
    [string]$RightLabel = 'RIGHT',
    [int]$Context = 3
)
$ErrorActionPreference = 'Stop'

function Read-Norm([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    return @(Get-Content -LiteralPath $p | ForEach-Object { $_ -replace '\s+$', '' })
}
$a = Read-Norm $LeftFile
$b = Read-Norm $RightFile
$n = $a.Count; $m = $b.Count

$header = @("--- $LeftLabel ($n lines)", "+++ $RightLabel ($m lines)")

if ($n -eq 0 -and $m -eq 0) {
    [System.IO.File]::WriteAllLines($OutFile, @($header + '(both empty)'), (New-Object System.Text.UTF8Encoding($false)))
    Write-Output 'DIFF: identical'; exit 0
}

# ---- large-pair guardrail: set-diff fallback (still honest, just not positional)
if ([double]$n * [double]$m -gt 4000000) {
    $cmp = Compare-Object -ReferenceObject $a -DifferenceObject $b
    $rep = New-Object System.Collections.Generic.List[string]
    $header + "(FALLBACK: set-diff -- files too large for positional hunks)" | ForEach-Object { $rep.Add($_) }
    $add = 0; $del = 0
    foreach ($c in $cmp) { if ($c.SideIndicator -eq '=>') { $rep.Add("+ $($c.InputObject)"); $add++ } else { $rep.Add("- $($c.InputObject)"); $del++ } }
    [System.IO.File]::WriteAllLines($OutFile, $rep, (New-Object System.Text.UTF8Encoding($false)))
    if ($add -eq 0 -and $del -eq 0) { Write-Output 'DIFF: identical' } else { Write-Output "DIFF: added=$add removed=$del hunks=fallback" }
    exit 0
}

# ---- LCS DP (length table), then backtrack into an op stream ------------------
# Jagged array $dp[$i][$j] -- NOT a 2D [int[,]]: PowerShell parses $dp[$i,$j] as a
# multi-index that returns Object[], so `$dp[$i,$j] + 1` throws op_Addition. Jagged
# indexing is unambiguous.
$dp = New-Object 'int[][]' ($n + 1)
for ($i = 0; $i -le $n; $i++) { $dp[$i] = New-Object 'int[]' ($m + 1) }
for ($i = $n - 1; $i -ge 0; $i--) {
    for ($j = $m - 1; $j -ge 0; $j--) {
        if ($a[$i] -ceq $b[$j]) { $dp[$i][$j] = $dp[$i + 1][$j + 1] + 1 }
        elseif ($dp[$i + 1][$j] -ge $dp[$i][$j + 1]) { $dp[$i][$j] = $dp[$i + 1][$j] }
        else { $dp[$i][$j] = $dp[$i][$j + 1] }
    }
}
# op stream: each entry @{ op = ' '|'-'|'+' ; text ; la ; ra } (1-based line nums)
$ops = New-Object System.Collections.Generic.List[object]
$i = 0; $j = 0
while ($i -lt $n -and $j -lt $m) {
    if ($a[$i] -ceq $b[$j]) { $ops.Add(@{ op = ' '; text = $a[$i]; la = $i + 1; ra = $j + 1 }); $i++; $j++ }
    elseif ($dp[$i + 1][$j] -ge $dp[$i][$j + 1]) { $ops.Add(@{ op = '-'; text = $a[$i]; la = $i + 1; ra = 0 }); $i++ }
    else { $ops.Add(@{ op = '+'; text = $b[$j]; la = 0; ra = $j + 1 }); $j++ }
}
while ($i -lt $n) { $ops.Add(@{ op = '-'; text = $a[$i]; la = $i + 1; ra = 0 }); $i++ }
while ($j -lt $m) { $ops.Add(@{ op = '+'; text = $b[$j]; la = 0; ra = $j + 1 }); $j++ }

$added = @($ops | Where-Object { $_.op -eq '+' }).Count
$removed = @($ops | Where-Object { $_.op -eq '-' }).Count
if ($added -eq 0 -and $removed -eq 0) {
    [System.IO.File]::WriteAllLines($OutFile, @($header + '(identical)'), (New-Object System.Text.UTF8Encoding($false)))
    Write-Output 'DIFF: identical'; exit 0
}

# ---- group ops into context hunks --------------------------------------------
# a change index is any op that is not ' '. A hunk spans from Context lines before
# the first change to Context lines after the last, merging changes <= 2*Context apart.
$changeIdx = @(for ($k = 0; $k -lt $ops.Count; $k++) { if ($ops[$k].op -ne ' ') { $k } })
$out = New-Object System.Collections.Generic.List[string]
$header | ForEach-Object { $out.Add($_) }
$hunks = 0
$k = 0
while ($k -lt $changeIdx.Count) {
    $start = [Math]::Max(0, $changeIdx[$k] - $Context)
    $end = $changeIdx[$k]
    # extend while the next change is within 2*Context of current end
    while ($k + 1 -lt $changeIdx.Count -and ($changeIdx[$k + 1] - $end) -le (2 * $Context)) { $k++; $end = $changeIdx[$k] }
    $end = [Math]::Min($ops.Count - 1, $end + $Context)
    # hunk header line ranges
    $laFirst = 0; $raFirst = 0
    for ($x = $start; $x -le $end; $x++) { if ($laFirst -eq 0 -and $ops[$x].la) { $laFirst = $ops[$x].la }; if ($raFirst -eq 0 -and $ops[$x].ra) { $raFirst = $ops[$x].ra } }
    $laCount = @(for ($x = $start; $x -le $end; $x++) { if ($ops[$x].op -ne '+') { 1 } }).Count
    $raCount = @(for ($x = $start; $x -le $end; $x++) { if ($ops[$x].op -ne '-') { 1 } }).Count
    $hunks++
    $out.Add(("@@ -{0},{1} +{2},{3} @@" -f $laFirst, $laCount, $raFirst, $raCount))
    for ($x = $start; $x -le $end; $x++) { $out.Add(($ops[$x].op + $ops[$x].text)) }
    $k++
}
[System.IO.File]::WriteAllLines($OutFile, $out, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "DIFF: added=$added removed=$removed hunks=$hunks"
exit 0
