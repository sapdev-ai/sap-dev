# Requires PowerShell 5.1+
# Read-only JSONL analyzer for sap-dev logs.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LogDir,
    [string]$Since,
    [string]$Skill,
    [string]$Status,
    [int]$Top = 10,
    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $LogDir)) {
    Write-Host "Log directory not found: $LogDir"
    exit 0
}

$files = Get-ChildItem -LiteralPath $LogDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '\.log(\.\d+)?$' }

if (-not $files -or $files.Count -eq 0) {
    Write-Host "No log files found in: $LogDir"
    exit 0
}

$sinceDt = $null
if ($Since) {
    try { $sinceDt = [datetime]::Parse($Since) } catch {
        Write-Host "Invalid --since value: $Since"
        exit 1
    }
}

$total    = 0
$badLines = 0
$starts   = 0
$ends     = @()         # array of end records
$steps    = 0
$minTs    = $null
$maxTs    = $null

foreach ($f in $files) {
    $reader = $null
    try {
        $reader = [System.IO.StreamReader]::new($f.FullName)
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $total++
            $rec = $null
            try { $rec = $line | ConvertFrom-Json -ErrorAction Stop } catch { $badLines++; continue }
            if (-not $rec.ts) { $badLines++; continue }

            $tsDt = $null
            try { $tsDt = [datetime]::Parse($rec.ts) } catch { }
            if ($tsDt) {
                if (-not $minTs -or $tsDt -lt $minTs) { $minTs = $tsDt }
                if (-not $maxTs -or $tsDt -gt $maxTs) { $maxTs = $tsDt }
                if ($sinceDt -and $tsDt -lt $sinceDt) { continue }
            }
            if ($Skill  -and $rec.skill  -ne $Skill)  { continue }

            switch ($rec.phase) {
                'start' { $starts++ }
                'step'  { $steps++ }
                'end'   {
                    if ($Status -and $rec.status -ne $Status) { continue }
                    $ends += $rec
                }
            }
        }
    } finally {
        if ($reader) { $reader.Close() }
    }
}

# ---- Section 1: Overall ----
Write-Host ""
Write-Host "=== Overall ===" -ForegroundColor Cyan
Write-Host ("Log directory : {0}" -f $LogDir)
Write-Host ("Files scanned : {0}" -f $files.Count)
Write-Host ("Records       : {0} (bad_lines: {1})" -f $total, $badLines)
Write-Host ("Date range    : {0} -> {1}" -f $(if($minTs){$minTs.ToString('s')}else{'-'}), $(if($maxTs){$maxTs.ToString('s')}else{'-'}))
Write-Host ("Phase counts  : start={0}  step={1}  end={2}" -f $starts, $steps, $ends.Count)
if ($Since)  { Write-Host ("Filter --since : {0}" -f $Since) }
if ($Skill)  { Write-Host ("Filter --skill : {0}" -f $Skill) }
if ($Status) { Write-Host ("Filter --status: {0}" -f $Status) }

# ---- Section 2: Per-skill summary ----
function Get-Percentile {
    param([double[]]$Values, [double]$P)
    if (-not $Values -or $Values.Count -eq 0) { return 0 }
    $sorted = $Values | Sort-Object
    $idx = [int][math]::Ceiling($P * $sorted.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $sorted.Count) { $idx = $sorted.Count - 1 }
    return [int]$sorted[$idx]
}

$bySkill = @{}
foreach ($e in $ends) {
    $k = $e.skill
    if (-not $bySkill.ContainsKey($k)) {
        $bySkill[$k] = [pscustomobject]@{
            skill=$k; runs=0; SUCCESS=0; FAILED=0; SKIPPED=0; EXISTED=0; ABANDONED=0;
            durations=New-Object 'System.Collections.Generic.List[double]'
        }
    }
    $row = $bySkill[$k]
    $row.runs++
    if ($row.PSObject.Properties.Name -contains $e.status) { $row.($e.status) = $row.($e.status) + 1 }
    if ($null -ne $e.duration_ms) { [void]$row.durations.Add([double]$e.duration_ms) }
}

$summaryRows = $bySkill.Values | Sort-Object skill | ForEach-Object {
    [pscustomobject]@{
        skill     = $_.skill
        runs      = $_.runs
        SUCCESS   = $_.SUCCESS
        FAILED    = $_.FAILED
        SKIPPED   = $_.SKIPPED
        EXISTED   = $_.EXISTED
        ABANDONED = $_.ABANDONED
        p50_ms    = Get-Percentile -Values $_.durations.ToArray() -P 0.50
        p95_ms    = Get-Percentile -Values $_.durations.ToArray() -P 0.95
    }
}

Write-Host ""
Write-Host "=== Per-skill summary ===" -ForegroundColor Cyan
if ($summaryRows) {
    $summaryRows | Format-Table -AutoSize | Out-String | Write-Host
} else {
    Write-Host "(no end records matched)"
}

# ---- Section 3: Top error_class ----
$errs = $ends | Where-Object { $_.status -eq 'FAILED' -or $_.status -eq 'ABANDONED' }
$byErr = $errs | Where-Object { $_.error_class } | Group-Object error_class | ForEach-Object {
    $lastTs   = ($_.Group | Sort-Object ts -Descending | Select-Object -First 1).ts
    $skills   = ($_.Group | Select-Object -ExpandProperty skill -Unique) -join ','
    [pscustomobject]@{
        error_class = $_.Name
        count       = $_.Count
        last_seen   = $lastTs
        skills      = $skills
    }
} | Sort-Object count -Descending

Write-Host "=== Top error_class ===" -ForegroundColor Cyan
if ($byErr) {
    $byErr | Format-Table -AutoSize | Out-String | Write-Host
} else {
    Write-Host "(no error_class values found)"
}

# ---- Section 4: Recent FAILED ----
$recent = $errs | Sort-Object ts -Descending | Select-Object -First $Top | ForEach-Object {
    $msg = if ($_.error_msg) { ($_.error_msg -replace "[`r`n]+", ' / ') } else { '' }
    if ($msg.Length -gt 80) { $msg = $msg.Substring(0,77) + '...' }
    [pscustomobject]@{
        ts            = $_.ts
        skill         = $_.skill
        run_id        = $_.run_id
        parent_run_id = $_.parent_run_id
        error_class   = $_.error_class
        error_msg     = $msg
    }
}

Write-Host ("=== Recent FAILED runs (top {0}) ===" -f $Top) -ForegroundColor Cyan
if ($recent) {
    $recent | Format-Table -AutoSize | Out-String | Write-Host
} else {
    Write-Host "(no FAILED runs)"
}

# ---- Optional CSV ----
if ($CsvPath -and $summaryRows) {
    try {
        $dir = Split-Path -Parent $CsvPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $summaryRows | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Host ("CSV written: {0}" -f $CsvPath) -ForegroundColor Green
    } catch {
        Write-Host ("CSV export FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

exit 0
