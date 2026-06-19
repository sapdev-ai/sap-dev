# Offline tests for the run-scoped temp isolation helpers:
#   Get-SapRunTemp / Remove-SapStaleRunTemp  (sap_connection_lib.ps1)
#   sap_run_with_lock.ps1                    (global paste mutex)
#
# Pure-local, no SAP / RFC / GUI. Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-run-temp-helpers.ps1
# Exit 0 = all pass, 1 = a failure.

$ErrorActionPreference = 'Stop'
$shared   = Join-Path $PSScriptRoot '..\plugins\sap-dev-core\shared\scripts'
$connLib  = (Resolve-Path (Join-Path $shared 'sap_connection_lib.ps1')).Path
$lockCli  = (Resolve-Path (Join-Path $shared 'sap_run_with_lock.ps1')).Path
. $connLib

$fails = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "  PASS  $name" }
    else { Write-Host "  FAIL  $name" -ForegroundColor Red; $script:fails++ }
}

# Sandbox work dir (no spaces).
$wd = Join-Path $env:TEMP ('runtemp_test_' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $wd | Out-Null
try {

    Write-Host "`n== Get-SapRunTemp =="
    $dirs = 1..200 | ForEach-Object { Get-SapRunTemp -WorkDir $wd }
    Check 'mints 200 distinct dirs'        (($dirs | Select-Object -Unique).Count -eq 200)
    Check 'every dir exists'               (@($dirs | Where-Object { -not (Test-Path $_) }).Count -eq 0)
    Check 'all under {work_dir}\temp'      (@($dirs | Where-Object { (Split-Path -Parent $_) -ne (Join-Path $wd 'temp') }).Count -eq 0)
    Check 'name is run_<hex>'              (@($dirs | Where-Object { (Split-Path -Leaf $_) -notmatch '^run_[0-9a-f]{8}$' }).Count -eq 0)
    Check 'never equals {work_dir}\runtime' (@($dirs | Where-Object { $_ -eq (Join-Path $wd 'runtime') }).Count -eq 0)
    # The runtime-derivation family does Split-Path -Parent on the temp path; a
    # RUN_TEMP's parent must be {work_dir}\temp, NOT {work_dir}, so passing it to
    # those helpers would be wrong -- assert the parent is the base temp.
    Check "parent is base temp (not work_dir)" ((Split-Path -Parent $dirs[0]) -eq (Join-Path $wd 'temp'))

    Write-Host "`n== Remove-SapStaleRunTemp =="
    $base = Join-Path $wd 'temp'
    $old  = Join-Path $base 'run_oldoldld'; New-Item -ItemType Directory -Force -Path $old | Out-Null
    $new  = Join-Path $base 'run_newnewnw'; New-Item -ItemType Directory -Force -Path $new | Out-Null
    $keep = Join-Path $base 'notarun_dir';  New-Item -ItemType Directory -Force -Path $keep | Out-Null
    (Get-Item $old).LastWriteTime = (Get-Date).AddHours(-48)
    $removed = Remove-SapStaleRunTemp -WorkDir $wd -MaxAgeHours 24
    Check 'stale run_ dir removed'         (-not (Test-Path $old))
    Check 'fresh run_ dir kept'            (Test-Path $new)
    Check 'non-run_ dir untouched'         (Test-Path $keep)
    Check 'returns a count >= 1'           ($removed -ge 1)

    # Native powershell.exe calls below may write to stderr (the lock CLI's
    # timeout diagnostic); under -EA Stop that surfaces as NativeCommandError.
    # Switch to Continue for the subprocess section -- assertions use exit codes.
    $ErrorActionPreference = 'Continue'

    Write-Host "`n== sap_run_with_lock.ps1 : exit-code passthrough =="
    & powershell -NoProfile -ExecutionPolicy Bypass -File $lockCli -MutexName "SapDevTest_$PID" -TimeoutMs 5000 -Command "cmd /c exit 7" 2>$null | Out-Null
    Check 'propagates wrapped exit code (7)' ($LASTEXITCODE -eq 7)

    Write-Host "`n== sap_run_with_lock.ps1 : serialization =="
    $probe = Join-Path $wd 'lock_probe.ps1'
    $log   = Join-Path $wd 'lock_log.txt'
    @'
param([string]$Log)
Add-Content -LiteralPath $Log -Value ("START {0} {1}" -f $PID, [DateTime]::UtcNow.Ticks)
Start-Sleep -Milliseconds 700
Add-Content -LiteralPath $Log -Value ("END   {0} {1}" -f $PID, [DateTime]::UtcNow.Ticks)
'@ | Set-Content -LiteralPath $probe -Encoding UTF8
    $mtx = "SapDevTestSerial_$PID"
    # Quote-free command (sandbox paths have no spaces), passed as a job arg so
    # no command-line quoting is involved -- mirrors real skill usage where the
    # wrapped command is `cscript //NoLogo <RUN_TEMP>\..vbs` (also space-free).
    $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File $probe -Log $log"
    $sb = { param($cli,$m,$c) & powershell -NoProfile -ExecutionPolicy Bypass -File $cli -MutexName $m -TimeoutMs 30000 -Command $c }
    $j1 = Start-Job -ScriptBlock $sb -ArgumentList $lockCli, $mtx, $cmd
    $j2 = Start-Job -ScriptBlock $sb -ArgumentList $lockCli, $mtx, $cmd
    Wait-Job -Job $j1, $j2 -Timeout 60 | Out-Null
    # Do NOT Receive-Job: the lock CLI writes a benign "acquired" diagnostic to
    # stderr, which Receive-Job would re-raise as an error under -EA Stop. We read
    # results from the log file instead.
    Remove-Job -Job $j1, $j2 -Force
    $lines = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
    # Parse two intervals; assert they do not overlap (mutex serialized them).
    $starts = @{}; $intervals = @()
    foreach ($ln in $lines) {
        $t = $ln -split '\s+'
        if ($t[0] -eq 'START') { $starts[$t[1]] = [int64]$t[2] }
        elseif ($t[0] -eq 'END') { $intervals += ,@([int64]$starts[$t[1]], [int64]$t[2]) }
    }
    $overlap = $false
    if ($intervals.Count -eq 2) {
        $a = $intervals[0]; $b = $intervals[1]
        # overlap iff a.start < b.end AND b.start < a.end
        if (($a[0] -lt $b[1]) -and ($b[0] -lt $a[1])) { $overlap = $true }
    }
    Check 'two runs recorded'              ($intervals.Count -eq 2)
    Check 'critical sections DID NOT overlap' (-not $overlap)

    Write-Host "`n== sap_run_with_lock.ps1 : acquire timeout =="
    $heldName = "SapDevTestHeld_$PID"
    $held = [System.Threading.Mutex]::new($false, $heldName)
    [void]$held.WaitOne(2000)
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $lockCli -MutexName $heldName -TimeoutMs 1200 -Command "cmd /c exit 0" 2>$null | Out-Null
        Check 'returns 2 when mutex unavailable' ($LASTEXITCODE -eq 2)
    } finally {
        $held.ReleaseMutex(); $held.Dispose()
    }

} finally {
    Remove-Item -LiteralPath $wd -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($fails -eq 0) { Write-Host "ALL TESTS PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$fails TEST(S) FAILED" -ForegroundColor Red; exit 1 }
