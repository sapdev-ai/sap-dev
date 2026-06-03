# Requires PowerShell 5.1+
# Read-only offline analyzer for SAP performance traces, part of /sap-trace.
#
# Accepts a tab-delimited trace export (from --import or the ST05/SAT GUI
# templates): ST05 "Summarized SQL Statements" or SAT runtime-analysis hit list.
# Normalizes -> ranks by total time -> flags anti-patterns -> maps each to a
# rule in abap_code_quality_rules.md (via perf_antipattern_map.tsv) -> renders a
# report and (optionally) a normalized JSON.
#
# Parseable last line: HOTSPOTS=<n> / TRACE_EMPTY: <reason> / ERROR: <msg>
# Exit: 0 success (incl. empty), 2 input/IO error.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputFile,
    [ValidateSet('st05','sat','auto')][string]$Kind = 'auto',
    [int]$Top = 20,
    [int]$ThresholdMs = 100,
    [ValidateSet('small','medium','large')][string]$PerfBand = 'medium',
    [string]$RuleMap,
    [string]$OutputJson,
    [switch]$WithSource
)

$ErrorActionPreference = 'Stop'

# ---------------- helpers ----------------
function Get-Cell([string[]]$p, [int]$idx) {
    if ($idx -ge 0 -and $idx -lt $p.Count) { return $p[$idx].Trim() }
    return ''
}

function ConvertTo-Num([string]$s) {
    if ($null -eq $s) { return [int64]0 }
    $t = ($s -replace '[^\d\-]', '')
    if ($t -eq '' -or $t -eq '-') { return [int64]0 }
    try { return [int64]$t } catch { return [int64]0 }
}

function Score-Header([string[]]$cells, [string[]]$keys) {
    $joined = ($cells -join '|').ToLower()
    $n = 0
    foreach ($k in $keys) { if ($joined -like "*$k*") { $n++ } }
    return $n
}

function Find-Col([string[]]$cells, [string[]]$alts) {
    # Priority order: try each alt across ALL columns before the next alt, so a
    # high-priority keyword (e.g. 'object') wins over a lower one (e.g. 'table')
    # even when the lower keyword appears in an earlier column ("Table Type").
    foreach ($a in $alts) {
        for ($c = 0; $c -lt $cells.Count; $c++) {
            if ($cells[$c].Trim().ToLower() -like "*$a*") { return $c }
        }
    }
    return -1
}

# ---------------- input ----------------
if (-not (Test-Path -LiteralPath $InputFile)) {
    Write-Host "ERROR: input file not found: $InputFile"
    exit 2
}

$rawLines = @(Get-Content -LiteralPath $InputFile -ErrorAction Stop |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($rawLines.Count -lt 2) {
    Write-Host "TRACE_EMPTY: file has no data rows"
    exit 0
}

$st05Keys = @('execution','identic','durat','record','object','statement','operation','program')
$satKeys  = @('net','gross','call','type','name')

$headerIdx = -1
$headerCells = $null
for ($i = 0; $i -lt $rawLines.Count; $i++) {
    $cells = $rawLines[$i].Split("`t")
    if ($cells.Count -lt 2) { continue }
    if ((Score-Header $cells $st05Keys) -ge 3 -or (Score-Header $cells $satKeys) -ge 3) {
        $headerIdx = $i; $headerCells = $cells; break
    }
}
if ($headerIdx -lt 0) {
    Write-Host "TRACE_EMPTY: could not locate a recognizable ST05/SAT header row"
    exit 0
}
if (($headerIdx + 1) -gt ($rawLines.Count - 1)) {
    Write-Host "TRACE_EMPTY: header row has no data rows beneath it"
    exit 0
}

if ($Kind -eq 'auto') {
    $s1 = Score-Header $headerCells $st05Keys
    $s2 = Score-Header $headerCells $satKeys
    $Kind = if ($s2 -gt $s1) { 'sat' } else { 'st05' }
}

$dataLines = $rawLines[($headerIdx + 1)..($rawLines.Count - 1)]
$records = New-Object System.Collections.Generic.List[object]

# ---------------- parse ----------------
if ($Kind -eq 'st05') {
    $cExec = Find-Col $headerCells @('execution')
    # ST05 "Redundancy" = count of identical/redundant executions (the loop signal);
    # "Identical [%]" is the ratio. Prefer the count.
    $cIden = Find-Col $headerCells @('redundan','identic')
    $cDur  = Find-Col $headerCells @('durat','time')
    $cRec  = Find-Col $headerCells @('record')
    $cObj  = Find-Col $headerCells @('object','table')
    $cStmt = Find-Col $headerCells @('statement','stmt')
    $cProg = Find-Col $headerCells @('program','prog')
    foreach ($ln in $dataLines) {
        $p = $ln.Split("`t")
        $exec  = ConvertTo-Num (Get-Cell $p $cExec)
        $iden  = ConvertTo-Num (Get-Cell $p $cIden)
        $durUs = ConvertTo-Num (Get-Cell $p $cDur)
        $rec   = ConvertTo-Num (Get-Cell $p $cRec)
        $obj   = Get-Cell $p $cObj
        $stmt  = Get-Cell $p $cStmt
        $prog  = Get-Cell $p $cProg
        if ($obj -eq '' -and $stmt -eq '') { continue }   # ST05 totals/summary row
        if ($exec -eq 0 -and $durUs -eq 0) { continue }
        $totalMs = [math]::Round($durUs / 1000.0, 1)
        $avgMs   = if ($exec -gt 0) { [math]::Round($totalMs / $exec, 3) } else { $totalMs }
        $recPerExec = if ($exec -gt 0) { [math]::Round($rec / [double]$exec, 1) } else { [double]$rec }
        $flags = New-Object System.Collections.Generic.List[string]
        $su = $stmt.ToUpper()
        if ($iden -ge 2)            { [void]$flags.Add('SELECT_IN_LOOP') }
        if ($exec -ge 100)         { [void]$flags.Add('MANY_CALLS') }
        if ($su -match 'SELECT\s*\*') { [void]$flags.Add('SELECT_STAR') }
        if ($su -like 'SELECT*' -and $su -notlike '*WHERE*') { [void]$flags.Add('NO_WHERE') }
        if ($recPerExec -ge 100000) { [void]$flags.Add('FULL_SCAN') }
        [void]$records.Add([pscustomobject]@{
            kind='SQL'; object=$obj; statement=$stmt; executions=$exec;
            identical=$iden; records=$rec; rec_per_exec=$recPerExec;
            total_ms=$totalMs; avg_ms=$avgMs; src_program=$prog;
            flags=$flags.ToArray()
        })
    }
}
elseif ($Kind -eq 'sat') {
    # SAT Hit List columns (1909): "Number of Hits..." | "Gross [microsec]" |
    # "Net [microsec]" | "Gross [%]" | "Net [%]" | "Statement/Event" |
    # "Program Called" | "Calling Program". Priority-ordered so 'net'/'gross'
    # pick the microsec column over the % one, 'hit' wins over 'call' (which
    # would otherwise grab "Calling Program"), and the unit is "Statement/Event".
    $cNet  = Find-Col $headerCells @('net')
    $cGro  = Find-Col $headerCells @('gross')
    $cCall = Find-Col $headerCells @('hit','call')
    $cName = Find-Col $headerCells @('statement','event','name')
    $cType = Find-Col $headerCells @('program called','called','type')
    foreach ($ln in $dataLines) {
        $p = $ln.Split("`t")
        $netUs = ConvertTo-Num (Get-Cell $p $cNet)
        $groUs = ConvertTo-Num (Get-Cell $p $cGro)
        $calls = ConvertTo-Num (Get-Cell $p $cCall)
        $type  = Get-Cell $p $cType
        $name  = Get-Cell $p $cName
        if ($netUs -eq 0 -and $name -eq '') { continue }
        $totalMs = [math]::Round($netUs / 1000.0, 1)
        $grossMs = [math]::Round($groUs / 1000.0, 1)
        $flags = New-Object System.Collections.Generic.List[string]
        [void]$flags.Add('ABAP_HOTSPOT')
        if ($calls -ge 1000) { [void]$flags.Add('MANY_CALLS') }
        [void]$records.Add([pscustomobject]@{
            kind='ABAP'; object=$name; statement=$type; executions=$calls;
            identical=0; records=0; rec_per_exec=0;
            total_ms=$totalMs; avg_ms=0; gross_ms=$grossMs; src_program='';
            flags=$flags.ToArray()
        })
    }
}

if ($records.Count -eq 0) {
    Write-Host "TRACE_EMPTY: no parseable data rows under header"
    exit 0
}

# ---------------- threshold + rank ----------------
$hot = @($records | Where-Object { $_.total_ms -ge $ThresholdMs } |
    Sort-Object -Property total_ms -Descending | Select-Object -First $Top)
if ($hot.Count -eq 0) {
    Write-Host "TRACE_EMPTY: no statements at or above ${ThresholdMs}ms (lower --threshold-ms to see more)"
    exit 0
}

# ---------------- severity by perf band ----------------
$bandHigh = switch ($PerfBand) { 'small' { 50 } 'medium' { 500 } 'large' { 5000 } default { 500 } }
foreach ($h in $hot) {
    $sev = if ($h.total_ms -ge $bandHigh) { 'HIGH' } elseif ($h.total_ms -ge ($bandHigh / 5)) { 'MED' } else { 'LOW' }
    $h | Add-Member -NotePropertyName severity -NotePropertyValue $sev -Force
}

# ---------------- rule map (built-in defaults, override from TSV) ----------------
$map = @{}
$default = @(
  @('SELECT_IN_LOOP','abap_code_quality_rules.md section 12 (SELECT in loop)','Identical SELECTs repeated -- likely a SELECT inside a LOOP or missing buffering','Pre-select all needed rows into an internal table before the loop; inside the loop use READ TABLE ... BINARY SEARCH or a hashed table.'),
  @('SELECT_STAR','abap_code_quality_rules.md section 12 (SELECT *)','SELECT * reads every column','Replace SELECT * with an explicit field list of only the columns consumed downstream.'),
  @('FAE_UNGUARDED','abap_code_quality_rules.md section 12 (FOR ALL ENTRIES)','FOR ALL ENTRIES without empty-check / SORT+dedupe','Guard with IF lt_keys IS NOT INITIAL; SORT lt_keys and DELETE ADJACENT DUPLICATES before SELECT ... FOR ALL ENTRIES.'),
  @('FULL_SCAN','abap_code_quality_rules.md section 12 (indexing)','Very high records-per-execution -- likely full table scan / poor index use','Add a selective WHERE on key/indexed fields; verify with ST05 Explain; consider a secondary index.'),
  @('NO_WHERE','abap_code_quality_rules.md section 12 (indexing)','SELECT with no restrictive WHERE','Add selective WHERE conditions on key/indexed fields; avoid reading the whole table.'),
  @('MANY_CALLS','abap_code_quality_rules.md section 12 (SELECT in loop)','Statement executed very many times','Hoist the call out of the loop / buffer the result; aggregate into one set-based read.'),
  @('ABAP_HOTSPOT','abap_code_quality_rules.md section 12 (internal tables)','ABAP-side net-time hotspot','Profile the unit; check nested LOOPs, linear READ TABLE (use BINARY SEARCH / hashed table), and avoidable recomputation.'),
  @('NESTED_LOOP','abap_code_quality_rules.md section 12 (internal tables)','Nested internal-table loop','Replace the inner LOOP with READ TABLE ... BINARY SEARCH or a hashed/sorted secondary key.')
)
foreach ($d in $default) { $map[$d[0]] = [pscustomobject]@{ rule_ref=$d[1]; pattern=$d[2]; fix=$d[3] } }
if ($RuleMap -and (Test-Path -LiteralPath $RuleMap)) {
    foreach ($ln in (Get-Content -LiteralPath $RuleMap | Where-Object { $_ -and ($_ -notmatch '^\s*#') })) {
        $c = $ln.Split("`t")
        if ($c.Count -ge 4 -and $c[0].Trim() -ne 'signal_id') {
            $map[$c[0].Trim()] = [pscustomobject]@{ rule_ref=$c[1].Trim(); pattern=$c[2].Trim(); fix=$c[3].Trim() }
        }
    }
}

# ---------------- report ----------------
Write-Host ""
Write-Host "=== /sap-trace analysis ===" -ForegroundColor Cyan
Write-Host ("Input        : {0}" -f $InputFile)
Write-Host ("Trace kind   : {0}" -f $Kind.ToUpper())
Write-Host ("Perf band    : {0}  (HIGH >= {1} ms)" -f $PerfBand, $bandHigh)
Write-Host ("Threshold    : {0} ms   Parsed rows: {1}   Hotspots: {2}" -f $ThresholdMs, $records.Count, $hot.Count)

Write-Host ""
Write-Host "=== Hotspots (ranked by total time) ===" -ForegroundColor Cyan
$rank = 0
$view = $hot | ForEach-Object {
    $rank++
    [pscustomobject]@{
        '#'      = $rank
        Object   = $_.object
        Total_ms = $_.total_ms
        Exec     = $_.executions
        Ident    = $_.identical
        Rec      = $_.records
        Sev      = $_.severity
        Flags    = ($_.flags -join ',')
    }
}
$view | Format-Table -AutoSize | Out-String | Write-Host

Write-Host "=== Findings & fixes ===" -ForegroundColor Cyan
$rank = 0
foreach ($h in $hot) {
    $rank++
    foreach ($fl in $h.flags) {
        $m = $map[$fl]
        if (-not $m) { continue }
        Write-Host ("#{0} {1}  [{2}]" -f $rank, $h.object, $fl)
        Write-Host ("    rule : {0}" -f $m.rule_ref)
        Write-Host ("    why  : {0}" -f $m.pattern)
        Write-Host ("    fix  : {0}" -f $m.fix)
        if ($WithSource -and $h.src_program) { Write-Host ("    src  : {0}" -f $h.src_program) }
    }
}

# ---------------- JSON ----------------
if ($OutputJson) {
    try {
        $dir = Split-Path -Parent $OutputJson
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $payload = [pscustomobject]@{
            meta = [pscustomobject]@{
                input        = $InputFile
                kind         = $Kind
                perf_band    = $PerfBand
                threshold_ms = $ThresholdMs
                parsed       = $records.Count
                hotspots     = $hot.Count
            }
            hotspots = $hot
        }
        $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputJson -Encoding UTF8
        Write-Host ("JSON written : {0}" -f $OutputJson) -ForegroundColor Green
    } catch {
        Write-Host ("WARN: JSON export failed: {0}" -f $_.Exception.Message)
    }
}

Write-Host ("HOTSPOTS={0}" -f $hot.Count)
exit 0
