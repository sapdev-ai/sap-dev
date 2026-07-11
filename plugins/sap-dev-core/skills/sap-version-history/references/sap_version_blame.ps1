# =============================================================================
# sap_version_blame.ps1  -  offline per-line blame for /sap-version-history
#
# Attributes every line of the NEWEST fetched version to the version that
# INTRODUCED it, by LCS-chaining consecutive versions newest->oldest: a line that
# still matches into the older version has its attribution pushed back to that
# older version; the first version a line stops matching into is where it was
# introduced. Lines that still match into the oldest version IN THE WINDOW, when
# older versions exist beyond it, are honestly marked OLDER_THAN_WINDOW (never
# guessed). Pure offline -- no SAP connection; the caller (sap-version-history
# Step 5) fetches the sources via sap_version_rfc.ps1 and passes them here.
#
#   -Files "<versno>=<path>,<versno>=<path>,..."   newest-first, window-ordered
#   -MetaTsv <version_list.tsv>   (VERSNO<TAB>...AUTHOR..DATUM..TRKORR.. header)
#   -OutTsv <blame.tsv> -OutAnnotated <blame_annotated.txt> [-HasOlder]
#
# Emits: BLAME: lines=<n> versions=<k> older_than_window=<o>  + STATUS: OK
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$Files,
    [string]$MetaTsv = '',
    [Parameter(Mandatory = $true)][string]$OutTsv,
    [string]$OutAnnotated = '',
    [switch]$HasOlder
)
$ErrorActionPreference = 'Stop'

# ---- parse the newest-first file list ----------------------------------------
$specs = @($Files -split ',' | Where-Object { $_ } | ForEach-Object {
        $kv = $_ -split '=', 2
        @{ versno = ("{0:D8}" -f [int]($kv[0].Trim())); path = $kv[1].Trim() }
    })
if ($specs.Count -eq 0) { Write-Output 'STATUS: INPUT_ERROR reason=no_files'; exit 2 }

function Read-Norm([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    return @(Get-Content -LiteralPath $p | ForEach-Object { $_ -replace '\s+$', '' })
}
$srcs = @($specs | ForEach-Object { , (Read-Norm $_.path) })   # array of line-arrays, newest-first
$vers = @($specs | ForEach-Object { $_.versno })

# ---- version metadata (author/date/tr per versno) ----------------------------
$meta = @{ }
if ($MetaTsv -and (Test-Path -LiteralPath $MetaTsv)) {
    $rows = Get-Content -LiteralPath $MetaTsv
    $hdr = ($rows[0] -split "`t")
    $ix = @{ }; for ($c = 0; $c -lt $hdr.Count; $c++) { $ix[$hdr[$c]] = $c }
    foreach ($line in ($rows | Select-Object -Skip 1)) {
        $f = $line -split "`t"
        $vn = "{0:D8}" -f [int]($f[$ix['VERSNO']])
        $meta[$vn] = @{ AUTHOR = $f[$ix['AUTHOR']]; DATUM = $f[$ix['DATUM']]; TRKORR = $(if ($ix.ContainsKey('TRKORR')) { $f[$ix['TRKORR']] } else { '' }) }
    }
}

# ---- LCS match map: younger index -> older index (or -1 if added) ------------
function Get-LcsMatch($ay, $ao) {
    $ny = $ay.Count; $no = $ao.Count
    $out = New-Object 'int[]' $ny
    for ($t = 0; $t -lt $ny; $t++) { $out[$t] = -1 }
    if ($ny -eq 0 -or $no -eq 0) { return $out }
    if ([double]$ny * [double]$no -gt 4000000) {
        # guardrail: exact-line hash fallback (order-insensitive, still honest)
        $seen = @{ }; for ($t = 0; $t -lt $no; $t++) { $seen[$ao[$t]] = $t }
        for ($t = 0; $t -lt $ny; $t++) { if ($seen.ContainsKey($ay[$t])) { $out[$t] = $seen[$ay[$t]] } }
        return $out
    }
    $dp = New-Object 'int[][]' ($ny + 1)
    for ($t = 0; $t -le $ny; $t++) { $dp[$t] = New-Object 'int[]' ($no + 1) }
    for ($t = $ny - 1; $t -ge 0; $t--) {
        for ($u = $no - 1; $u -ge 0; $u--) {
            if ($ay[$t] -ceq $ao[$u]) { $dp[$t][$u] = $dp[$t + 1][$u + 1] + 1 }
            elseif ($dp[$t + 1][$u] -ge $dp[$t][$u + 1]) { $dp[$t][$u] = $dp[$t + 1][$u] }
            else { $dp[$t][$u] = $dp[$t][$u + 1] }
        }
    }
    $t = 0; $u = 0
    while ($t -lt $ny -and $u -lt $no) {
        if ($ay[$t] -ceq $ao[$u]) { $out[$t] = $u; $t++; $u++ }
        elseif ($dp[$t + 1][$u] -ge $dp[$t][$u + 1]) { $t++ }
        else { $u++ }
    }
    return $out
}

# precompute match maps for each consecutive pair (younger v, older v+1)
$maps = @()
for ($v = 0; $v -lt $srcs.Count - 1; $v++) { $maps += , (Get-LcsMatch $srcs[$v] $srcs[$v + 1]) }

# ---- attribute each newest line ----------------------------------------------
$newest = $srcs[0]
$oldestIdx = $srcs.Count - 1
$blameTsv = New-Object System.Collections.Generic.List[string]
$blameTsv.Add("LINE_NO`tVERSNO`tAUTHOR`tDATUM`tTRKORR`tTEXT")
$annot = New-Object System.Collections.Generic.List[string]
$olderCount = 0
for ($i = 0; $i -lt $newest.Count; $i++) {
    $curIdx = $i; $attr = $vers[0]; $reachedOldest = ($srcs.Count -eq 1)
    for ($v = 0; $v -lt $maps.Count; $v++) {
        $older = $maps[$v][$curIdx]
        if ($older -ge 0) { $curIdx = $older; $attr = $vers[$v + 1]; if ($v + 1 -eq $oldestIdx) { $reachedOldest = $true } }
        else { break }
    }
    if ($reachedOldest -and $HasOlder) { $attr = 'OLDER_THAN_WINDOW'; $olderCount++ }
    $mv = $meta[$attr]
    $au = if ($mv) { $mv.AUTHOR } else { '' }
    $dt = if ($mv) { $mv.DATUM } else { '' }
    $tr = if ($mv) { $mv.TRKORR } else { '' }
    $txt = $newest[$i]
    $blameTsv.Add(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f ($i + 1), $attr, $au, $dt, $tr, $txt))
    $annot.Add(("{0,6} {1,-17} {2,-12} {3}" -f $attr, $au, $dt, $txt))
}
[System.IO.File]::WriteAllLines($OutTsv, $blameTsv, (New-Object System.Text.UTF8Encoding($true)))
if ($OutAnnotated) { [System.IO.File]::WriteAllLines($OutAnnotated, $annot, (New-Object System.Text.UTF8Encoding($false))) }
Write-Output ("BLAME: lines={0} versions={1} older_than_window={2}" -f $newest.Count, $srcs.Count, $olderCount)
Write-Output 'STATUS: OK'
exit 0
