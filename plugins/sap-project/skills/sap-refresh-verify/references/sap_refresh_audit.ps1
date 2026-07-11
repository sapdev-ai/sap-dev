# =============================================================================
# sap_refresh_audit.ps1  -  Read-only post-refresh audit engine for /sap-refresh-verify
#
# RFC-only (NCo 3.1, 32-bit PS). Audits the pinned system against an operator-owned
# expectations config and emits doctor-style CHECK lines + a GO/GO_WITH_WARNINGS/
# NO_GO verdict. Zero SAP writes. sost/SAPconnect is delegated by the SKILL, not here.
#
#   -Action identity  : RFC_SYSTEM_INFO + T000 vs config sid/client (pre-gate).
#                       IDENTITY: sid=.. cfg_sid=.. client=.. match=<1|0>  + STATUS
#   -Action audit     : the full check battery.
#                       CHECK: id=<id> group=<g> result=<PASS|FAIL|REVIEW|SKIP|COULD_NOT_CHECK> detail="..." fix="..."
#                       VERDICT: GO | GO_WITH_WARNINGS | NO_GO
#
# Verdict: any FAIL -> NO_GO; any REVIEW/COULD_NOT_CHECK -> GO_WITH_WARNINGS; else GO.
# Exit: 0 audit ran, 1 config/identity refusal, 2 connect error.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Action = 'audit',
    [string] $Config = '',
    [int]    $MaxRows = 5000,
    [string] $OutDir = '',
    [string] $SharedDir = '',
    [string] $RunId = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function Sq { param([string]$s) return (("$s") -replace "'", "''") }
function San { param([string]$s) return (("$s") -replace '"',"'" -replace "[`t`r`n]",' ').Trim() }
$script:results = New-Object System.Collections.Generic.List[object]
function Check {
    param([string]$Id,[string]$Group,[string]$Result,[string]$Detail,[string]$Fix='')
    Write-Host ("CHECK: id=$Id group=$Group result=$Result detail=`"$(San $Detail)`" fix=`"$(San $Fix)`"")
    $script:results.Add([pscustomobject]@{ id=$Id; group=$Group; result=$Result; detail=$Detail; fix=$Fix })
}

# ---- load config ----
if (-not $Config -or -not (Test-Path $Config)) { Write-Host "STATUS: REFRESH_CONFIG_MISSING"; Write-Host "INFO: no expectations config; run /sap-refresh-verify init-config"; exit 1 }
try { $cfg = Get-Content $Config -Raw | ConvertFrom-Json } catch { Write-Host "STATUS: REFRESH_CONFIG_INVALID detail=json_parse"; exit 1 }
$reqd = @('sid','client','expected_logsys')
foreach ($k in $reqd) { if (-not $cfg.$k) { Write-Host "STATUS: REFRESH_CONFIG_INVALID detail=missing_$k"; exit 1 } }
function CfgArr($name) { if ($cfg.$name) { return @($cfg.$name) } else { return @() } }

$g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_REFRESH"
if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR detail=connect"; exit 2 }
$cli = if ($Client) { $Client } elseif ($cfg.client) { "$($cfg.client)" } else { '100' }

# ---- identity ----
$sysid = ''
try { $fi = $g_dest.Repository.CreateFunction('RFC_SYSTEM_INFO'); $fi.Invoke($g_dest); $sysid = "$($fi.GetStructure('RFCSI_EXPORT').GetString('RFCSYSID'))".Trim() } catch {}
$idMatch = ($sysid -eq "$($cfg.sid)".ToUpper())
if ($Action -eq 'identity') {
    Write-Host ("IDENTITY: sid=$sysid cfg_sid=$($cfg.sid) client=$cli match=" + ($(if ($idMatch) {'1'} else {'0'})))
    Write-Host ($(if ($idMatch) { "STATUS: OK" } else { "STATUS: REFRESH_IDENTITY_MISMATCH" }))
    try { Disconnect-SapRfc } catch {}; exit ($(if ($idMatch) {0} else {1}))
}

if ($MyInvocation.InvocationName -ne '.') {
try {
    # identity/system
    if ($idMatch) { Check 'identity/system' 'identity' 'PASS' "connected SID=$sysid matches config" }
    else { Check 'identity/system' 'identity' 'FAIL' "connected SID=$sysid but config expects $($cfg.sid) - auditing the WRONG system" 'abort; pin the correct profile via /sap-login'; Write-Host "VERDICT: NO_GO"; try { Disconnect-SapRfc } catch {}; exit 0 }

    # client/logsys + role
    $t0 = @(); try { $t0 = Read-SapTableRows -Destination $g_dest -Table 'T000' -Where "MANDT EQ '$(Sq $cli)'" -Fields @('MANDT','MTEXT','LOGSYS','CCCATEGORY') -RowCount 1 } catch {}
    if (@($t0).Count) {
        $logsys = "$($t0[0].LOGSYS)".Trim(); $cat = "$($t0[0].CCCATEGORY)".Trim()
        $expLog = "$($cfg.expected_logsys)".ToUpper()
        if ($logsys.ToUpper() -eq $expLog) { Check 'client/logsys' 'client' 'PASS' "LOGSYS=$logsys matches expected" }
        else {
            $prdHit = $false; foreach ($p in (CfgArr 'prd_logsys_patterns')) { if ($logsys.ToUpper() -like ("*"+"$p".ToUpper().Replace('*','')+"*")) { $prdHit=$true } }
            if ($prdHit) { Check 'client/logsys' 'client' 'FAIL' "LOGSYS=$logsys still points at a PRD logical system - BDLS not run" 'run BDLS (t-code) to convert LOGSYS, then re-audit' }
            else { Check 'client/logsys' 'client' 'REVIEW' "LOGSYS=$logsys does not match expected ($expLog) and no PRD pattern matched" 'confirm the logical system is correct for this client (SCC4/BDLS)' }
        }
        $expRole = if ($cfg.expected_client_role) { "$($cfg.expected_client_role)".ToUpper() } else { 'T' }
        if ($cat.ToUpper() -eq $expRole) { Check 'client/role' 'client' 'PASS' "CCCATEGORY=$cat matches expected role" }
        elseif ($cat.ToUpper() -eq 'P') { Check 'client/role' 'client' 'FAIL' "CCCATEGORY=P (Production) on a non-production copy" 'set the client role to Test/Customizing in SCC4' }
        else { Check 'client/role' 'client' 'REVIEW' "CCCATEGORY=$cat != expected $expRole" 'confirm client role in SCC4' }
    } else { Check 'client/logsys' 'client' 'COULD_NOT_CHECK' "T000 read returned no row for client $cli" 'grant S_TABU_DIS for the basis auth group of T000' }

    # client/logsys-defined (TBDLS)
    $tb = @(); try { $tb = Read-SapTableRows -Destination $g_dest -Table 'TBDLS' -Where "" -Fields @('LOGSYS') -RowCount $MaxRows } catch {}
    if (@($tb).Count) {
        $defined = @($tb | ForEach-Object { "$($_.LOGSYS)".ToUpper() })
        if ($defined -contains "$($cfg.expected_logsys)".ToUpper()) { Check 'client/logsys-defined' 'client' 'PASS' "expected LOGSYS is defined in TBDLS" }
        else { Check 'client/logsys-defined' 'client' 'FAIL' "expected LOGSYS $($cfg.expected_logsys) not in TBDLS - BDLS/SALE incomplete" 'define the logical system (BD54/SALE) before BDLS' }
    } else { Check 'client/logsys-defined' 'client' 'COULD_NOT_CHECK' 'TBDLS unreadable' '' }

    # rfc/prd-pointing
    $patterns = @(CfgArr 'prd_host_patterns'); $allow = @(CfgArr 'rfc_allow' | ForEach-Object { "$_".ToUpper() })
    if ($patterns.Count -eq 0) { Check 'rfc/prd-pointing' 'rfc' 'COULD_NOT_CHECK' 'no prd_host_patterns configured' 'add prd_host_patterns[] to the expectations config' }
    else {
        $hits = @{}; $cnc = $false
        foreach ($pat in $patterns) {
            $pp = "$pat".Trim(); if ($pp -eq '' -or $pp -match '[%_]') { $cnc=$true; continue }
            try {
                $rows = Read-SapTableRows -Destination $g_dest -Table 'RFCDES' -Where "RFCOPTIONS LIKE '%$(Sq $pp)%'" -Fields @('RFCDEST','RFCTYPE') -RowCount $MaxRows
                foreach ($r in $rows) { $dn="$($r.RFCDEST)".Trim(); if ($dn) { $hits[$dn] = "$($r.RFCTYPE)" } }
            } catch { $cnc=$true }
        }
        $bad = @($hits.Keys | Where-Object { $allow -notcontains $_.ToUpper() })
        $allowed = @($hits.Keys | Where-Object { $allow -contains $_.ToUpper() })
        if ($bad.Count -gt 0) { Check 'rfc/prd-pointing' 'rfc' 'FAIL' ("destinations still pointing at PRD host patterns: " + ($bad -join ',')) 'repoint or delete in SM59, or add to rfc_allow[] if intentional' }
        elseif ($allowed.Count -gt 0) { Check 'rfc/prd-pointing' 'rfc' 'REVIEW' ("only allowlisted PRD-pointing destinations found: " + ($allowed -join ',')) 're-confirm each allowlisted destination is still intended after this refresh' }
        elseif ($cnc) { Check 'rfc/prd-pointing' 'rfc' 'COULD_NOT_CHECK' 'one or more patterns could not be LIKE-encoded or read' '' }
        else { Check 'rfc/prd-pointing' 'rfc' 'PASS' 'no destinations match the configured PRD host patterns' }
    }

    # jobs/released
    $jobAllow = @(CfgArr 'job_allow' | ForEach-Object { "$_".ToUpper() })
    $jobs = @{}
    foreach ($st in @('S','Y','R')) {
        try { $jr = Read-SapTableRows -Destination $g_dest -Table 'TBTCO' -Where "STATUS EQ '$st'" -Fields @('JOBNAME','JOBCOUNT','SDLUNAME','STATUS','PERIODIC') -RowCount $MaxRows
              foreach ($j in $jr) { $key="$($j.JOBNAME)|$($j.JOBCOUNT)"; $jobs[$key]=$j } } catch {}
    }
    $badJobs = @($jobs.Values | Where-Object { $jn="$($_.JOBNAME)".ToUpper(); $ok=$false; foreach($p in $jobAllow){ if($jn -like ("$p".Replace('*','')+"*") -or $jn -like $p){$ok=$true} }; -not $ok })
    if ($badJobs.Count -gt 0) {
        $per = @($badJobs | Where-Object { "$($_.PERIODIC)".Trim() -ne '' }).Count
        $names = (@($badJobs | Select-Object -First 10 | ForEach-Object { "$($_.JOBNAME)/$($_.JOBCOUNT)" }) -join ',')
        Check 'jobs/released' 'jobs' 'FAIL' ("$($badJobs.Count) non-allowlisted released/ready/active jobs ($per periodic): $names") 'deschedule with /sap-refresh-verify deschedule <JOBNAME> <JOBCOUNT> (or --all-flagged)'
        if ($OutDir) { $flagged = @($badJobs | ForEach-Object { "$($_.JOBNAME)`t$($_.JOBCOUNT)`t$($_.SDLUNAME)`t$($_.STATUS)`t$($_.PERIODIC)" }); [System.IO.File]::WriteAllText((Join-Path $OutDir 'jobs_flagged.tsv'), ("jobname`tjobcount`tsdluname`tstatus`tperiodic`r`n" + ($flagged -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true))) }
    } else { Check 'jobs/released' 'jobs' 'PASS' 'no non-allowlisted released jobs' }

    # queues/qout + qin via the SMQ FMs
    $backlogIs = if ("$($cfg.queue_backlog_is)".ToUpper() -eq 'REVIEW') { 'REVIEW' } else { 'FAIL' }
    foreach ($qf in @(@{fm='TRFC_QOUT_GET_CURRENT_QUEUES';id='queues/qout'}, @{fm='TRFC_QIN_GET_CURRENT_QUEUES';id='queues/qin'})) {
        try {
            $fn = $g_dest.Repository.CreateFunction($qf.fm); $fn.SetValue('CLIENT',$cli); $fn.SetValue('QNAME','*'); $fn.Invoke($g_dest)
            $qv = $fn.GetTable('QVIEW'); $qn = $qv.RowCount
            if ($qn -gt 0) { Check $qf.id 'queues' $backlogIs "$qn queue(s) with entries (SMQ1/SMQ2)" 'clear/deregister queues in SMQ1/SMQ2 after confirming they are refresh residue' }
            else { Check $qf.id 'queues' 'PASS' 'no current queues' }
        } catch { Check $qf.id 'queues' 'COULD_NOT_CHECK' ("queue FM failed: " + (San $_.Exception.Message)) 'check S_RFC for the SMQ FMs; SMQ1/SMQ2 manual review' }
    }
    # queues/trfc (ARFCSSTATE)
    try {
        $ar = Read-SapTableRows -Destination $g_dest -Table 'ARFCSSTATE' -Where "" -Fields @('ARFCIPID','ARFCDEST') -RowCount $MaxRows
        $an = @($ar).Count
        if ($an -gt 0) { $dests=@($ar | ForEach-Object { "$($_.ARFCDEST)" } | Where-Object { $_ } | Select-Object -Unique); Check 'queues/trfc' 'queues' $backlogIs "$an pending outbound tRFC LUW(s) (SM58) to: $(( $dests | Select-Object -First 8) -join ',')" 'process/delete stuck LUWs in SM58 after confirming they are refresh residue' }
        else { Check 'queues/trfc' 'queues' 'PASS' 'no pending outbound tRFC LUWs' }
    } catch { Check 'queues/trfc' 'queues' 'COULD_NOT_CHECK' 'ARFCSSTATE unreadable' '' }

    # users/lock-policy
    $lockPolicy = if ($cfg.lock_policy) { "$($cfg.lock_policy)".ToUpper() } else { 'NONE' }
    if ($lockPolicy -eq 'NONE') { Check 'users/lock-policy' 'users' 'SKIP' 'lock_policy=NONE' '' }
    else {
        $userAllow = @(CfgArr 'user_allow' | ForEach-Object { "$_".ToUpper() })
        try {
            $us = Read-SapTableRows -Destination $g_dest -Table 'USR02' -Where "USTYP EQ 'A'" -Fields @('BNAME','UFLAG') -RowCount $MaxRows
            $violators = @()
            foreach ($u in $us) {
                $bn="$($u.BNAME)".ToUpper(); if ($userAllow -contains $bn) { continue }
                $uf = 0; [int]::TryParse("$($u.UFLAG)".Trim(), [ref]$uf) | Out-Null
                $adminLocked = ((($uf -band 32) -ne 0) -or (($uf -band 64) -ne 0))
                if (-not $adminLocked) { $violators += $bn }
            }
            if ($violators.Count -gt 0) { Check 'users/lock-policy' 'users' 'FAIL' ("$($violators.Count) dialog user(s) not admin-locked: $((@($violators)|Select-Object -First 12) -join ',')") 'admin-lock inherited dialog users with SU10 (a failed-logon lock 128 does not count)' }
            else { Check 'users/lock-policy' 'users' 'PASS' 'all dialog users (minus allowlist) are admin-locked' }
        } catch { Check 'users/lock-policy' 'users' 'COULD_NOT_CHECK' 'USR02 unreadable' '' }
    }

    # mail/sost -> delegated by the SKILL
    Check 'mail/sost' 'mail' 'SKIP' 'SAPconnect config-check is delegated to /sap-sost by the skill (SKIP if not installed)' 'install /sap-sost for SAPconnect coverage'

    # ---- verdict ----
    $hasFail = @($script:results | Where-Object { $_.result -eq 'FAIL' }).Count -gt 0
    $hasWarn = @($script:results | Where-Object { $_.result -in @('REVIEW','COULD_NOT_CHECK') }).Count -gt 0
    $verdict = if ($hasFail) { 'NO_GO' } elseif ($hasWarn) { 'GO_WITH_WARNINGS' } else { 'GO' }

    if ($OutDir) {
        $tsv = @("id`tgroup`tresult`tdetail`tfix") + @($script:results | ForEach-Object { "$($_.id)`t$($_.group)`t$($_.result)`t$(San $_.detail)`t$(San $_.fix)" })
        [System.IO.File]::WriteAllText((Join-Path $OutDir 'refresh_checks.tsv'), ($tsv -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
    }
    Write-Host ("VERDICT: $verdict")
    Write-Host "STATUS: OK"
    try { Disconnect-SapRfc } catch {}
    exit 0
} catch {
    Write-Host ("STATUS: RFC_ERROR detail=" + (San $_.Exception.Message))
    try { Disconnect-SapRfc } catch {}
    exit 2
}
}
