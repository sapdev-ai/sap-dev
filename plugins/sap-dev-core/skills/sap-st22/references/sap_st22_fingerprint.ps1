# =============================================================================
# sap_st22_fingerprint.ps1  -  /sap-st22 dump fingerprinting + recurrence ledger
#
# PURE LOCAL (no SAP / no RFC): a post-processing layer over the ST22 reader's
# evidence_st22.json. For each dump event it computes a stable fingerprint, upserts
# a team-shareable ledger, and prints a NEW / KNOWN_RECURRING / GONE delta.
#
#   fingerprint = SHA1(exception|program|include|line)  when include+line known
#                                                       (precision=deep)
#               = SHA1(exception|program)               otherwise (precision=list)
#   -- the precision column keeps the two grains distinct so they never collide
#      silently: a dump seen only list-level and later deep-level yields a coarse
#      row AND a fine row (deep adds the failing line, which the list grain can't
#      know), rather than one being mistaken for the other.
#
# Best-effort: never changes the reader verdict. A missing evidence file or a
# ledger IO error is reported and exits 0.
#
# Ledger: {custom_url}\ops_kb\dump_fingerprints.tsv (also feeds /sap-diagnose
# --kb match, /sap-health-check trend, /sap-evidence-pack). Columns:
#   fingerprint precision exception program include line first_seen last_seen count sample_dump_key
#
# Params: -EvidenceFile <evidence_st22.json> -LedgerPath <ledger.tsv>
#         [-GoneDays 7] [-Today yyyyMMdd]
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$EvidenceFile,
    [Parameter(Mandatory = $true)][string]$LedgerPath,
    [int]$GoneDays = 7,
    [string]$Today = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Today) { $Today = (Get-Date).ToString('yyyyMMdd') }
$cols = @('fingerprint', 'precision', 'exception', 'program', 'include', 'line', 'first_seen', 'last_seen', 'count', 'sample_dump_key')

function Get-Fp([string]$s) {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { $hex = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    return $hex.Substring(0, 16)
}

if (-not (Test-Path $EvidenceFile)) { Write-Host "STATUS: SKIP evidence_missing $EvidenceFile"; exit 0 }
try {
    $ev = [IO.File]::ReadAllText($EvidenceFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
} catch { Write-Host "STATUS: SKIP evidence_unreadable $($_.Exception.Message)"; exit 0 }
$events = @($ev.events)
if ($events.Count -eq 0) { Write-Host "STATUS: OK new=0 recurring=0 gone=0 (no dumps in evidence)"; exit 0 }

# ---- run fingerprints (dedupe N identical dumps in this window) -------------
$run = @{}
foreach ($e in $events) {
    $exc = "$($e.tech.exception)".Trim(); if (-not $exc) { $exc = "$($e.msg_id)".Trim() }
    $prog = "$($e.program)".Trim()
    $inc = "$($e.include)".Trim(); $line = "$($e.line)".Trim()
    $sample = "$($e.tech.dump_key)".Trim()
    if ($inc -and $line) { $fp = Get-Fp "$exc|$prog|$inc|$line"; $prec = 'deep' }
    else { $fp = Get-Fp "$exc|$prog"; $prec = 'list' }
    if (-not $run.ContainsKey($fp)) {
        $run[$fp] = @{ precision = $prec; exception = $exc; program = $prog; include = $inc; line = $line; count = 0; sample = $sample }
    }
    $run[$fp].count++
}

# ---- load ledger -----------------------------------------------------------
$ledger = @{}
if (Test-Path $LedgerPath) {
    try {
        $ll = [IO.File]::ReadAllLines($LedgerPath, [Text.Encoding]::UTF8)
        for ($i = 1; $i -lt $ll.Count; $i++) {
            if (-not $ll[$i]) { continue }
            $p = $ll[$i] -split "`t"
            if ($p.Count -lt $cols.Count) { continue }
            $row = [ordered]@{}; for ($k = 0; $k -lt $cols.Count; $k++) { $row[$cols[$k]] = $p[$k] }
            $ledger[$row.fingerprint] = $row
        }
    } catch { Write-Host "STATUS: SKIP ledger_unreadable $($_.Exception.Message)"; exit 0 }
}

# ---- classify + upsert -----------------------------------------------------
$new = @(); $recurring = @()
foreach ($fp in $run.Keys) {
    $r = $run[$fp]
    if ($ledger.ContainsKey($fp)) {
        $recurring += $fp
        $L = $ledger[$fp]
        $L.last_seen = $Today
        $L.count = [string]([int]$L.count + $r.count)
        if (-not $L.sample_dump_key) { $L.sample_dump_key = $r.sample }
    } else {
        $new += $fp
        $ledger[$fp] = [ordered]@{ fingerprint = $fp; precision = $r.precision; exception = $r.exception
            program = $r.program; include = $r.include; line = $r.line; first_seen = $Today; last_seen = $Today
            count = [string]$r.count; sample_dump_key = $r.sample
        }
    }
}

# ---- GONE: in ledger, not in this run, last_seen >= GoneDays ago ------------
$gone = @()
foreach ($fp in @($ledger.Keys)) {
    if ($run.ContainsKey($fp)) { continue }
    $L = $ledger[$fp]
    $days = try { ([datetime]::ParseExact($Today, 'yyyyMMdd', $null) - [datetime]::ParseExact($L.last_seen, 'yyyyMMdd', $null)).Days } catch { 0 }
    if ($days -ge $GoneDays) { $gone += @{ fp = $fp; days = $days; L = $L } }
}

# ---- write ledger back -----------------------------------------------------
try {
    $lines = @($cols -join "`t")
    foreach ($fp in ($ledger.Keys | Sort-Object)) { $L = $ledger[$fp]; $lines += (@($cols | ForEach-Object { "$($L[$_])" }) -join "`t") }
    $dir = Split-Path -Parent $LedgerPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($LedgerPath, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
} catch { Write-Host "STATUS: SKIP ledger_write_failed $($_.Exception.Message)"; exit 0 }

# ---- emit delta ------------------------------------------------------------
foreach ($fp in $new) { $r = $run[$fp]; Write-Host ("FINGERPRINT: {0} precision={1} status=NEW count={2} exception={3} program={4} dump_key={5}" -f $fp, $r.precision, $r.count, $r.exception, $r.program, $r.sample) }
foreach ($fp in $recurring) { $r = $run[$fp]; $L = $ledger[$fp]; Write-Host ("FINGERPRINT: {0} precision={1} status=KNOWN_RECURRING count={2} total={3} first_seen={4} exception={5} program={6}" -f $fp, $r.precision, $r.count, $L.count, $L.first_seen, $r.exception, $r.program) }
foreach ($g in $gone) { $L = $g.L; Write-Host ("GONE: {0} days={1} last_seen={2} exception={3} program={4}" -f $g.fp, $g.days, $L.last_seen, $L.exception, $L.program) }
Write-Host ("STATUS: OK new={0} recurring={1} gone={2} ledger={3}" -f $new.Count, $recurring.Count, $gone.Count, $LedgerPath)
