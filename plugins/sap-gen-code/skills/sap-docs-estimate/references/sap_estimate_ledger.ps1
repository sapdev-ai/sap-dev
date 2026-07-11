# =============================================================================
# sap_estimate_ledger.ps1  -  append-only estimate/actuals ledger for /sap-docs-estimate
#
# LOCAL ONLY. Makes every estimate falsifiable: an ESTIMATE row is written when a spec is
# scored; record-actuals appends an ACTUAL row keyed by the same estimate_id. Corrections are
# new rows (never edits) so history is preserved. `pairs` joins ESTIMATE<->ACTUAL for calibrate.
#
#   record  -Id <estimate_id> -Kind ESTIMATE|ACTUAL -ScopeKey <k> [-Class <c>] [-BandLow <n>] [-BandHigh <n>] [-Phase build|test|total] [-Hours <n>] [-Source <s>] [-Note <t>] -LedgerFile <tsv>
#   list    [-Id <estimate_id>] -LedgerFile <tsv>
#   pairs   [-MinPairs N] -LedgerFile <tsv>
#
# stdout: EST_LEDGER: ... + STATUS: OK | EST_LEDGER_IO | EST_ID_UNKNOWN | EST_CALIBRATION_INSUFFICIENT ; exit 0/1/2
# =============================================================================
[CmdletBinding()]
param(
    [ValidateSet('record','list','pairs')]
    [string] $Action    = 'list',
    [string] $Id        = '',
    [ValidateSet('ESTIMATE','ACTUAL','')]
    [string] $Kind      = '',
    [string] $ScopeKey  = '',
    [string] $Class     = '',
    [string] $BandLow   = '',
    [string] $BandHigh  = '',
    [string] $Phase     = 'total',
    [string] $Hours     = '',
    [string] $Source    = '',
    [string] $Note      = '',
    [int]    $MinPairs  = 8,
    [string] $LedgerFile= ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$COLS = 'estimate_id','ts','kind','scope_key','class','band_low','band_high','phase','hours','source','note'

if (-not $LedgerFile) { Write-Host 'STATUS: EST_LEDGER_IO reason=no_ledger_path'; exit 2 }
$dir = Split-Path $LedgerFile -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

function Read-Ledger {
    $out = @()
    if (-not (Test-Path $LedgerFile)) { return $out }
    $lines = @([IO.File]::ReadAllLines($LedgerFile))
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]; if (-not "$ln".Trim() -or "$ln".StartsWith('#')) { continue }
        $c = $ln -split "`t"; if ($c[0] -eq 'estimate_id') { continue }
        $rec = [ordered]@{}
        for ($j = 0; $j -lt $COLS.Count; $j++) { $rec[$COLS[$j]] = if ($j -lt $c.Count) { $c[$j] } else { '' } }
        $out += ,([pscustomobject]$rec)
    }
    return $out
}

if ($Action -eq 'record') {
    if (-not $Id)   { Write-Host 'STATUS: EST_LEDGER_IO reason=no_id'; exit 2 }
    if (-not $Kind) { Write-Host 'STATUS: EST_LEDGER_IO reason=no_kind'; exit 2 }
    $existing = @(Read-Ledger)
    if ($Kind -eq 'ACTUAL') {
        $known = @($existing | Where-Object { $_.estimate_id -eq $Id -and $_.kind -eq 'ESTIMATE' })
        if ($known.Count -eq 0) { Write-Host ("STATUS: EST_ID_UNKNOWN id={0}" -f $Id); exit 1 }
    }
    # write header if new file
    if (-not (Test-Path $LedgerFile)) { [IO.File]::WriteAllText($LedgerFile, (($COLS -join "`t") + "`r`n"), (New-Object Text.UTF8Encoding($true))) }
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $vals = @($Id,$ts,$Kind,$ScopeKey,$Class,$BandLow,$BandHigh,$Phase,$Hours,$Source,($Note -replace "`t",' '))
    $line = ($vals -join "`t")
    $ok = $false
    for ($try = 0; $try -lt 5 -and -not $ok; $try++) {
        try { $sw = [IO.StreamWriter]::new($LedgerFile, $true, (New-Object Text.UTF8Encoding($false))); $sw.WriteLine($line); $sw.Flush(); $sw.Close(); $ok = $true } catch { Start-Sleep -Milliseconds 120 }
    }
    if (-not $ok) { Write-Host 'STATUS: EST_LEDGER_IO reason=append_failed'; exit 2 }
    $pairN = @(@(Read-Ledger) | Where-Object { $_.estimate_id -eq $Id -and $_.kind -eq 'ACTUAL' }).Count
    Write-Host ("EST_LEDGER: recorded id={0} kind={1} phase={2} hours={3}" -f $Id,$Kind,$Phase,$Hours)
    Write-Host ("STATUS: OK action=record id={0} actuals_for_id={1}" -f $Id,$pairN)
    exit 0
}
elseif ($Action -eq 'list') {
    $rows = @(Read-Ledger)
    if ($Id) { $rows = @($rows | Where-Object { $_.estimate_id -eq $Id }) }
    foreach ($r in $rows) { Write-Host ("EST_LEDGER: id={0} ts={1} kind={2} scope={3} class={4} band={5}-{6} phase={7} hours={8}" -f $r.estimate_id,$r.ts,$r.kind,$r.scope_key,$r.class,$r.band_low,$r.band_high,$r.phase,$r.hours) }
    Write-Host ("STATUS: OK action=list rows={0}" -f $rows.Count)
    exit 0
}
elseif ($Action -eq 'pairs') {
    $rows = @(Read-Ledger)
    $ids = @($rows | ForEach-Object { $_.estimate_id } | Select-Object -Unique)
    $paired = @()
    foreach ($eid in $ids) {
        $est = @($rows | Where-Object { $_.estimate_id -eq $eid -and $_.kind -eq 'ESTIMATE' } | Select-Object -First 1)
        $act = @($rows | Where-Object { $_.estimate_id -eq $eid -and $_.kind -eq 'ACTUAL' -and $_.phase -eq 'total' } | Select-Object -Last 1)
        if ($est.Count -and $act.Count) {
            $mid = ([double]$est[0].band_low + [double]$est[0].band_high) / 2.0
            $paired += [pscustomobject]@{ id=$eid; class=$est[0].class; mid_pd=$mid; actual_h=$act[0].hours }
            Write-Host ("EST_PAIR: id={0} class={1} mid_pd={2} actual_hours={3}" -f $eid,$est[0].class,$mid,$act[0].hours)
        }
    }
    if ($paired.Count -lt $MinPairs) { Write-Host ("STATUS: EST_CALIBRATION_INSUFFICIENT pairs={0} need={1}" -f $paired.Count,$MinPairs); exit 1 }
    Write-Host ("STATUS: OK action=pairs pairs={0}" -f $paired.Count)
    exit 0
}
