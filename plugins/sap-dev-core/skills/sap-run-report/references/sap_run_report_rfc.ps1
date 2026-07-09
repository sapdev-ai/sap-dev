# =============================================================================
# sap_run_report_rfc.ps1  -  Phase B RFC background backend for /sap-run-report
#
# Submits an ABAP report as a background job via the RFC-enabled Z_RUN_REPORT
# (JOB_OPEN -> SUBMIT VIA JOB -> JOB_CLOSE; deployed by /sap-dev-init), then
# polls TBTCO for completion and reads TBTCP for the spool id (LISTIDENT). Emits
# the RUN_REPORT: lines the SKILL.md Step 4/5 parse; the SKILL.md then captures
# the spool text via /sap-sp02 <LISTIDENT> and (on abort) /sap-st22.
#
# 32-bit PowerShell (NCo 3.1). Read-only except the job submit inside Z_RUN_REPORT.
# Dot-sources sap_rfc_lib.ps1 (Connect-SapRfc / New-RfcReadTable / Add-RfcField /
# Add-RfcOption); resolve via -RfcLib or the ../../shared fallback.
#
# Args:
#   -Program <REPORT>    ABAP report name (required)
#   -Variant <VAR>       variant name (optional)
#   -JobName <NAME>      job name (optional; default = program)
#   -Timeout <sec>       poll cap, default 300
#   -PollInterval <sec>  poll interval, default 5
#   -RfcLib <path>       sap_rfc_lib.ps1 (optional; auto-resolved otherwise)
#
# Output (last line parseable):
#   RUN_REPORT: SUBMITTED job=<n> count=<c>
#   RUN_REPORT: COMPLETED job=<n> count=<c> status=F spool=<LISTIDENT|NONE>
#   RUN_REPORT: DUMP      job=<n> count=<c> status=A
#   RUN_REPORT: TIMEOUT   job=<n> count=<c> status=<s> timeout=<t>s
#   RUN_REPORT: SUBMIT_FAILED program=<p> status=<Z_RUN_REPORT EV_STATUS>
#   ERROR: <...>
# Exit: 0 = completed / submitted-ok, 1 = dump / timeout / submit-failed,
#       2 = infra (RFC connect / lib / FM missing)
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$Program,
    [string]$Variant = '',
    [string]$JobName = '',
    [int]$Timeout = 300,
    [int]$PollInterval = 5,
    [string]$RfcLib = ''
)
$ErrorActionPreference = 'Stop'
$Program = $Program.ToUpper()
if ($Variant -ne '') { $Variant = $Variant.ToUpper() }

# --- resolve sap_rfc_lib.ps1 ---
if ($RfcLib -eq '' -or -not (Test-Path $RfcLib)) {
    $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $cand = Join-Path $root 'shared\scripts\sap_rfc_lib.ps1'
    if (Test-Path $cand) { $RfcLib = $cand }
}
if (-not (Test-Path $RfcLib)) { Write-Output 'ERROR: sap_rfc_lib.ps1 not found (pass -RfcLib)'; exit 2 }
. $RfcLib

try { $dest = Connect-SapRfc } catch { Write-Output "ERROR: RFC connect failed: $($_.Exception.Message)"; exit 2 }

# --- 1. Submit the background job via Z_RUN_REPORT ---
try {
    $fn = $dest.Repository.CreateFunction('Z_RUN_REPORT')
    [void]$fn.SetValue('IV_PROGRAM', $Program)
    if ($Variant -ne '') { [void]$fn.SetValue('IV_VARIANT', $Variant) }
    if ($JobName -ne '') { [void]$fn.SetValue('IV_JOBNAME', $JobName) }
    [void]$fn.SetValue('IV_IMMED', 'X')
    $fn.Invoke($dest)
    $status   = "$($fn.GetValue('EV_STATUS'))".Trim()
    $jobname  = "$($fn.GetValue('EV_JOBNAME'))".Trim()
    $jobcount = "$($fn.GetValue('EV_JOBCOUNT'))".Trim()
} catch {
    Write-Output "ERROR: Z_RUN_REPORT call failed: $($_.Exception.Message)"
    Write-Output '  (RFC background needs Z_RUN_REPORT -- deploy it via /sap-dev-init)'
    exit 1
}

if ($status -ne 'SUBMITTED') {
    Write-Output "RUN_REPORT: SUBMIT_FAILED program=$Program status=$status"
    exit 1
}
Write-Output "RUN_REPORT: SUBMITTED job=$jobname count=$jobcount"

# --- 2. Poll TBTCO until finished (F) / aborted (A) / timeout ---
$deadline = (Get-Date).AddSeconds($Timeout)
$jobStatus = ''
while ($true) {
    Start-Sleep -Seconds $PollInterval
    $t = New-RfcReadTable -Destination $dest -Table 'TBTCO'
    Add-RfcField  $t 'STATUS'
    Add-RfcOption $t "JOBNAME = '$jobname'"
    Add-RfcOption $t "AND JOBCOUNT = '$jobcount'"
    [void]$t.Invoke($dest)
    $rows = $t.GetTable('DATA')
    $jobStatus = ''
    foreach ($r in $rows) { $jobStatus = "$($r.GetString('WA'))".Trim(); break }
    if ($jobStatus -eq 'F' -or $jobStatus -eq 'A') { break }
    if ((Get-Date) -ge $deadline) { break }
}

if ($jobStatus -eq 'A') {
    Write-Output "RUN_REPORT: DUMP job=$jobname count=$jobcount status=A"
    exit 1
}
if ($jobStatus -ne 'F') {
    Write-Output "RUN_REPORT: TIMEOUT job=$jobname count=$jobcount status=$jobStatus timeout=${Timeout}s"
    exit 1
}

# --- 3. Read TBTCP for the generated spool id ---
$listident = 'NONE'
$tp = New-RfcReadTable -Destination $dest -Table 'TBTCP'
Add-RfcField  $tp 'LISTIDENT'
Add-RfcOption $tp "JOBNAME = '$jobname'"
Add-RfcOption $tp "AND JOBCOUNT = '$jobcount'"
[void]$tp.Invoke($dest)
$prows = $tp.GetTable('DATA')
foreach ($r in $prows) {
    $li = "$($r.GetString('WA'))".Trim()
    if ($li -ne '' -and $li -notmatch '^0+$') { $listident = [string][int64]$li; break }
}
Write-Output "RUN_REPORT: COMPLETED job=$jobname count=$jobcount status=F spool=$listident"
exit 0
