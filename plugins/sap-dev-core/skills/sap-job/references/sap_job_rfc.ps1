# =============================================================================
# sap_job_rfc.ps1  -  RFC backend for /sap-job (background job management)
#
# The RFC-preferred path for the /sap-job skill. Mirrors the verified Phase-B
# backend sap_run_report_rfc.ps1 (same NCo 3.1 plumbing, same read-only TBTCO/
# TBTCP reads, same Z_RUN_REPORT reuse for immediate scheduling). Each -Action
# emits a parseable JOB: line the SKILL.md Steps 4/5 read.
#
# Capability by action (read-only unless noted):
#   schedule  -> Z_RUN_REPORT (JOB_OPEN -> SUBMIT VIA JOB -> JOB_CLOSE, immediate
#                only; a report submit -- WRITE, gated by SKILL.md Step 2.5).
#                Start-time / periodic scheduling is GUI-only (SM36) -- this
#                backend emits SCHEDULE_NEEDS_GUI for those so the SKILL degrades.
#   list      -> RFC_READ_TABLE TBTCO (JOBNAME/SDLUNAME/STATUS/date filters).
#   status    -> RFC_READ_TABLE TBTCO on (JOBNAME, JOBCOUNT).
#   spool     -> RFC_READ_TABLE TBTCP.LISTIDENT on (JOBNAME, JOBCOUNT); the
#                SKILL then captures the text via /sap-sp02 <LISTIDENT>.
#   delete    -> BP_JOB_DELETE (SAP write API; removes a job definition).
#                Best-effort over direct RFC: on any exception (FM not remote-
#                enabled on this system) emits DELETE_NEEDS_GUI -> SM37 fallback.
#   log       -> not attempted here (job-log text lives in TemSe; cleanly read
#                only via the SM37 GUI list). Emits LOG_NEEDS_GUI by design.
#   cancel    -> not attempted here (aborting a RUNNING job needs the server/PID
#                that SM37's "Stop active job" resolves). Emits CANCEL_NEEDS_GUI.
#
# 32-bit PowerShell (NCo 3.1). Dot-sources sap_rfc_lib.ps1 (Connect-SapRfc /
# New-RfcReadTable / Add-RfcField / Add-RfcOption); resolve via -RfcLib or the
# ../../shared fallback.
#
# Args:
#   -Action  <schedule|list|status|spool|delete|log|cancel>   (required)
#   -Program <REPORT>     schedule: the ABAP report to run
#   -Variant <VAR>        schedule: variant (optional)
#   -JobName <NAME>       schedule: job name (default = program) / filters + keys
#   -JobCount <COUNT>     status|spool|delete: the 8-char job number
#   -User    <SDLUNAME>   list: scheduling user filter
#   -Status  <R|Y|P|S|A|F> list: TBTCO status filter
#   -FromDate <YYYYMMDD>  list: SDLSTRTDT lower bound (best-effort; see notes)
#   -ToDate   <YYYYMMDD>  list: SDLSTRTDT upper bound
#   -MaxRows <n>          list: ROWCOUNT cap (default 100)
#   -Start   <immediate|YYYYMMDDHHMMSS|event:<EVT>>  schedule start condition
#   -Period  <daily|weekly|monthly>                  schedule recurrence
#   -RfcLib  <path>       sap_rfc_lib.ps1 (optional; auto-resolved otherwise)
#
# Output (last JOB: line is authoritative):
#   JOB: SCHEDULED job=<n> count=<c>
#   JOB: SCHEDULE_NEEDS_GUI reason=<start_time|periodic>          (-> SM36)
#   JOB: LISTED n=<k> truncated=<0|1>            (+ JOBROW: tab-rows above it)
#   JOB: STATUS status=<code> statustext=<t> count=<c>
#   JOB: SPOOL spool=<LISTIDENT|NONE> count=<c>
#   JOB: DELETED count=<c>
#   JOB: <LOG|CANCEL|DELETE>_NEEDS_GUI reason=<...>               (-> SM37)
#   JOB: NOT_FOUND job=<n> count=<c>
#   JOB: SCHEDULE_FAILED program=<p> status=<Z_RUN_REPORT EV_STATUS>
#   ERROR: <...>
# Exit: 0 = op ok, 1 = negative result (NOT_FOUND / *_FAILED),
#       2 = infra (RFC connect / lib / FM missing),
#       3 = RFC path unavailable for this op -> SKILL.md degrades to GUI.
# =============================================================================
param(
    [Parameter(Mandatory = $true)][ValidateSet('schedule','list','status','spool','delete','log','cancel')][string]$Action,
    [string]$Program  = '',
    [string]$Variant  = '',
    [string]$JobName  = '',
    [string]$JobCount = '',
    [string]$User     = '',
    [string]$Status   = '',
    [string]$FromDate = '',
    [string]$ToDate   = '',
    [int]$MaxRows     = 100,
    [string]$Start    = 'immediate',
    [string]$Period   = '',
    [string]$RfcLib   = ''
)
$ErrorActionPreference = 'Stop'
if ($Program -ne '') { $Program = $Program.ToUpper() }
if ($Variant -ne '') { $Variant = $Variant.ToUpper() }

# --- TBTCO status code -> readable label (locale-independent codes) ----------
function Get-JobStatusText([string]$c) {
    switch ($c) {
        'R' { 'Active'    }   # running
        'Y' { 'Ready'     }
        'P' { 'Scheduled' }   # defined, no start condition released
        'S' { 'Released'  }   # start condition set, waiting to run
        'A' { 'Cancelled' }   # aborted / ended in error
        'F' { 'Finished'  }
        'Z' { 'Put_active'}
        'X' { 'Unknown_X' }
        default { if ($c -eq '') { 'Unknown' } else { $c } }
    }
}

# --- resolve sap_rfc_lib.ps1 (identical logic to sap_run_report_rfc.ps1) ------
if ($RfcLib -eq '' -or -not (Test-Path $RfcLib)) {
    $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $cand = Join-Path $root 'shared\scripts\sap_rfc_lib.ps1'
    if (Test-Path $cand) { $RfcLib = $cand }
}
if (-not (Test-Path $RfcLib)) { Write-Output 'ERROR: sap_rfc_lib.ps1 not found (pass -RfcLib)'; exit 2 }
. $RfcLib

try { $dest = Connect-SapRfc } catch { Write-Output "ERROR: RFC connect failed: $($_.Exception.Message)"; exit 2 }

# =============================================================================
switch ($Action) {

# ----- schedule -------------------------------------------------------------
'schedule' {
    if ($Program -eq '') { Write-Output 'ERROR: schedule needs -Program'; exit 2 }
    # Start-time / periodic scheduling is not expressible through Z_RUN_REPORT
    # (immediate submit only) -- degrade to the SM36 GUI wizard.
    if ($Period -ne '') { Write-Output "JOB: SCHEDULE_NEEDS_GUI reason=periodic";   exit 3 }
    if ($Start -ne '' -and $Start.ToLower() -ne 'immediate') { Write-Output "JOB: SCHEDULE_NEEDS_GUI reason=start_time"; exit 3 }

    try {
        $fn = $dest.Repository.CreateFunction('Z_RUN_REPORT')
        [void]$fn.SetValue('IV_PROGRAM', $Program)
        if ($Variant -ne '') { [void]$fn.SetValue('IV_VARIANT', $Variant) }
        if ($JobName -ne '') { [void]$fn.SetValue('IV_JOBNAME', $JobName) }
        [void]$fn.SetValue('IV_IMMED', 'X')
        $fn.Invoke($dest)
        $st = "$($fn.GetValue('EV_STATUS'))".Trim()
        $jn = "$($fn.GetValue('EV_JOBNAME'))".Trim()
        $jc = "$($fn.GetValue('EV_JOBCOUNT'))".Trim()
    } catch {
        Write-Output "ERROR: Z_RUN_REPORT call failed: $($_.Exception.Message)"
        Write-Output '  (RFC schedule needs Z_RUN_REPORT -- deploy it via /sap-dev-init, or use the SM36 GUI path)'
        exit 3   # degrade to GUI
    }
    if ($st -ne 'SUBMITTED') { Write-Output "JOB: SCHEDULE_FAILED program=$Program status=$st"; exit 1 }
    Write-Output "JOB: SCHEDULED job=$jn count=$jc"
    exit 0
}

# ----- list -----------------------------------------------------------------
'list' {
    $t = New-RfcReadTable -Destination $dest -Table 'TBTCO'
    Add-RfcField $t 'JOBNAME'
    Add-RfcField $t 'JOBCOUNT'
    Add-RfcField $t 'STATUS'
    Add-RfcField $t 'SDLUNAME'
    Add-RfcField $t 'SDLSTRTDT'
    Add-RfcField $t 'SDLSTRTTM'
    Add-RfcField $t 'ENDDATE'
    Add-RfcField $t 'ENDTIME'
    # WHERE (each row <=72 chars, explicit AND on continuations).
    $first = $true
    function _Opt($t, [string]$cond, [ref]$first) {
        if ($first.Value) { Add-RfcOption $t $cond; $first.Value = $false }
        else { Add-RfcOption $t ("AND " + $cond) }
    }
    if ($JobName -ne '') {
        if ($JobName -match '[\*%]') { $lk = ($JobName -replace '\*','%'); _Opt $t "JOBNAME LIKE '$lk'" ([ref]$first) }
        else { _Opt $t "JOBNAME EQ '$JobName'" ([ref]$first) }
    }
    # User: '*'/'%' (or empty) = no user filter; a wildcard value -> LIKE; else EQ.
    # (A bare "SDLUNAME EQ '*'" matches nobody -- the classic all-users trap.)
    if ($User -ne '' -and $User -ne '*' -and $User -ne '%') {
        if ($User -match '[\*%]') { _Opt $t "SDLUNAME LIKE '$(($User -replace '\*','%').ToUpper())'" ([ref]$first) }
        else { _Opt $t "SDLUNAME EQ '$($User.ToUpper())'" ([ref]$first) }
    }
    if ($Status   -ne '') { _Opt $t "STATUS EQ '$($Status.ToUpper())'" ([ref]$first) }
    if ($FromDate -ne '') { _Opt $t "SDLSTRTDT GE '$FromDate'" ([ref]$first) }
    if ($ToDate   -ne '') { _Opt $t "SDLSTRTDT LE '$ToDate'"   ([ref]$first) }
    if ($MaxRows -gt 0) { [void]$t.SetValue('ROWCOUNT', $MaxRows) }
    [void]$t.Invoke($dest)
    $rows = $t.GetTable('DATA')
    $n = 0
    foreach ($r in $rows) {
        $p = "$($r.GetString('WA'))".Split('|')
        for ($i = 0; $i -lt $p.Count; $i++) { $p[$i] = $p[$i].Trim() }
        $jn = $p[0]; $jc = $p[1]; $sc = $p[2]; $su = $p[3]
        $sd = $p[4]; $stm = $p[5]; $ed = $p[6]; $et = $p[7]
        $stext = Get-JobStatusText $sc
        # Tab-separated data row (job names may contain spaces).
        Write-Output ("JOBROW:`t$jn`t$jc`t$sc`t$stext`t$su`t$sd $stm`t$ed $et")
        $n++
    }
    $trunc = if ($MaxRows -gt 0 -and $n -ge $MaxRows) { 1 } else { 0 }
    Write-Output "JOB: LISTED n=$n truncated=$trunc"
    exit 0
}

# ----- status ---------------------------------------------------------------
'status' {
    if ($JobName -eq '' -or $JobCount -eq '') { Write-Output 'ERROR: status needs -JobName and -JobCount'; exit 2 }
    $t = New-RfcReadTable -Destination $dest -Table 'TBTCO'
    Add-RfcField $t 'STATUS'
    Add-RfcField $t 'SDLUNAME'
    Add-RfcField $t 'SDLSTRTDT'
    Add-RfcField $t 'SDLSTRTTM'
    Add-RfcField $t 'STRTDATE'
    Add-RfcField $t 'STRTTIME'
    Add-RfcField $t 'ENDDATE'
    Add-RfcField $t 'ENDTIME'
    Add-RfcOption $t "JOBNAME = '$JobName'"
    Add-RfcOption $t "AND JOBCOUNT = '$JobCount'"
    [void]$t.Invoke($dest)
    $rows = $t.GetTable('DATA')
    $hit = $null
    foreach ($r in $rows) { $hit = "$($r.GetString('WA'))"; break }
    if (-not $hit) { Write-Output "JOB: NOT_FOUND job=$JobName count=$JobCount"; exit 1 }
    $p = $hit.Split('|'); for ($i = 0; $i -lt $p.Count; $i++) { $p[$i] = $p[$i].Trim() }
    $sc = $p[0]; $stext = Get-JobStatusText $sc
    Write-Output "INFO: job=$JobName count=$JobCount user=$($p[1]) scheduled=$($p[2]) $($p[3]) started=$($p[4]) $($p[5]) ended=$($p[6]) $($p[7])"
    Write-Output "JOB: STATUS status=$sc statustext=$stext count=$JobCount"
    if ($sc -eq 'A') { exit 1 }   # aborted -> non-zero so the SKILL flags it
    exit 0
}

# ----- spool ----------------------------------------------------------------
'spool' {
    if ($JobName -eq '' -or $JobCount -eq '') { Write-Output 'ERROR: spool needs -JobName and -JobCount'; exit 2 }
    $tp = New-RfcReadTable -Destination $dest -Table 'TBTCP'
    Add-RfcField  $tp 'LISTIDENT'
    Add-RfcOption $tp "JOBNAME = '$JobName'"
    Add-RfcOption $tp "AND JOBCOUNT = '$JobCount'"
    [void]$tp.Invoke($dest)
    $prows = $tp.GetTable('DATA')
    $listident = 'NONE'
    foreach ($r in $prows) {
        $li = "$($r.GetString('WA'))".Trim()
        if ($li -ne '' -and $li -notmatch '^0+$') { $listident = [string][int64]$li; break }
    }
    Write-Output "JOB: SPOOL spool=$listident count=$JobCount"
    exit 0
}

# ----- delete ---------------------------------------------------------------
'delete' {
    if ($JobName -eq '' -or $JobCount -eq '') { Write-Output 'ERROR: delete needs -JobName and -JobCount'; exit 2 }
    # BP_JOB_DELETE is the SAP write API for removing a job definition (not raw
    # SQL on TBTCO). Best-effort over direct RFC -- if it is not remote-enabled
    # on this system the call throws and we degrade to the SM37 GUI delete.
    try {
        $fn = $dest.Repository.CreateFunction('BP_JOB_DELETE')
        [void]$fn.SetValue('JOBCOUNT', $JobCount)
        [void]$fn.SetValue('JOBNAME',  $JobName)
        $fn.Invoke($dest)
    } catch {
        Write-Output "JOB: DELETE_NEEDS_GUI reason=$($_.Exception.Message)"
        exit 3
    }
    # BP_JOB_DELETE signals failure via EXCEPTIONS (surfaced as an NCo throw
    # above) -- reaching here means the delete was accepted. Confirm via TBTCO.
    try {
        $t = New-RfcReadTable -Destination $dest -Table 'TBTCO'
        Add-RfcField  $t 'JOBNAME'
        Add-RfcOption $t "JOBNAME = '$JobName'"
        Add-RfcOption $t "AND JOBCOUNT = '$JobCount'"
        [void]$t.Invoke($dest)
        $still = $false
        foreach ($r in $t.GetTable('DATA')) { $still = $true; break }
        if ($still) { Write-Output "JOB: DELETE_NEEDS_GUI reason=still_present_after_call"; exit 3 }
    } catch { }
    Write-Output "JOB: DELETED count=$JobCount"
    exit 0
}

# ----- log / cancel : GUI-primary (see header) ------------------------------
'log'    { Write-Output "JOB: LOG_NEEDS_GUI reason=joblog_temse_read_is_gui_only";    exit 3 }
'cancel' { Write-Output "JOB: CANCEL_NEEDS_GUI reason=abort_running_needs_sm37_server"; exit 3 }

}
