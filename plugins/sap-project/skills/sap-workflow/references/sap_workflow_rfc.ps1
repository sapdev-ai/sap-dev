# =============================================================================
# sap_workflow_rfc.ps1  -  SAP Business Workflow runtime skill backend (/sap-workflow)
#
# One RFC-only backend, three modes (all FMs FMODE=R on S4D + EC2, probed 2026-07-11):
#   diagnose  find stuck/errored workitems for an anchor, decode the SWWLOGHIST error,
#             flag agent-determination gaps, report event-queue + linkage health
#   explain   dossier for a WS/TS task or live WI: text, definition status, triggering events
#   act       restart / cancel / forward a workitem via released SAP_WAPI_* write APIs,
#             behind a refusal matrix, verified by an authoritative SWWWIHEAD.WI_STAT re-read
#
# Reads: SWWWIHEAD, SWWLOGHIST, HRS1000, SWDSHEADER, SWETYPECOU, SWEQUEUE, T100 (msg text).
# Writes (act only): SAP_WAPI_ADM_WORKFLOW_RESTART / _CANCEL / SAP_WAPI_FORWARD_WORKITEM
#   (WORKITEM_ID + DO_COMMIT='X' -> RETURN_CODE + NEW_STATUS). No table writes (Rule 1);
#   no deploys, no wrapper FM (Rule 2). GUI SWIA is v2 -- RFC unavailable fails LOUD.
#
#   -Mode diagnose  [-WiId <id>] [-Task <TS/WS..>] [-User U] [-Status error|all] [-Since YYYYMMDD] [-Top N]
#   -Mode explain   -Task <WSnnnn|TSnnnn>  |  -WiId <id>
#   -Mode act       -Verb restart|cancel|forward  -WiId <id> [-To USER] [-DryRun]
#   [-Profile <hint>]  -OutDir <dir> [-SharedDir <dir>] [-RunId <id>]
#
# stdout: WF: / WFENV: / WFEXPL: / WFACT: lines (see each mode) + STATUS: <verdict>. Exit 0/1/2.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Mode      = 'diagnose',
    [string] $WiId      = '',
    [string] $Task      = '',
    [string] $User      = '',
    [string] $Status    = 'error',
    [string] $Since     = '',
    [int]    $Top       = 20,
    [string] $Object    = '',
    [string] $Verb      = '',
    [string] $To        = '',
    [switch] $DryRun,
    [string] $Profile   = '',
    [string] $OutDir    = '',
    [string] $SharedDir = '',
    [string] $RunId     = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
foreach ($lib in 'sap_connection_lib.ps1','sap_rfc_lib.ps1') { $pp = Join-Path $scripts $lib; if (Test-Path $pp) { . $pp } }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Invoke-Rfc { param($fn,$d) try { $fn.Invoke($d); return $true } catch { if ("$($_.Exception.Message)" -match 'TABLE_WITHOUT_DATA') { return $false } else { throw } } }
function Add-Where { param($fn,[string]$where)
    if (-not $where) { return }
    $line=''
    foreach ($cl in ($where -split '\s+AND\s+')) { $piece = if ($line -eq '') { $cl } else { "AND $cl" }; if ($line -eq '') { $line=$piece } elseif (($line.Length+1+$piece.Length) -le 72) { $line="$line $piece" } else { Add-RfcOption $fn $line; $line=$piece } }
    if ($line) { Add-RfcOption $fn $line }
}
function Read-Rows { param($d,[string]$table,[string]$where,[string[]]$fields,[int]$max)
    $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''
    if ($max -gt 0) { [void]$fn.SetValue('ROWCOUNT',$max) }
    if ($where) { Add-Where $fn $where }
    foreach ($f in $fields) { Add-RfcField $fn $f }
    if (-not (Invoke-Rfc $fn $d)) { return @() }
    $fm=$fn.GetTable('FIELDS');$off=@{};$len=@{};for($x=0;$x -lt $fm.RowCount;$x++){$fm.CurrentIndex=$x;$nm=(San $fm.GetString('FIELDNAME'));$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
    $dt=$fn.GetTable('DATA');$out=@();for($x=0;$x -lt $dt.RowCount;$x++){$dt.CurrentIndex=$x;$wa="$($dt.GetString('WA'))";$rec=[ordered]@{};foreach($f in $fields){$o=$off[$f];$l=$len[$f];$rec[$f]=if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).Trim()}else{''}};$out+=,([pscustomobject]$rec)}
    return $out
}
function Msg-Text { param($d,[string]$arbgb,[string]$msgnr)
    if (-not $arbgb -or -not $msgnr) { return '' }
    $r = @(Read-Rows $d 'T100' "SPRSL = 'E' AND ARBGB = '$arbgb' AND MSGNR = '$msgnr'" @('TEXT') 1)
    if ($r.Count) { return $r[0].TEXT } else { return '' }
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $OutDir) { Write-Host 'STATUS: WF_INPUT no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

# ---- connect (pinned profile, or -Profile hint for a targeted run) -----------
$d = $null
if ($Profile) {
    $cands = @(Resolve-SapProfileHint -Hint $Profile)
    if ($cands.Count -ne 1) { Write-Host "STATUS: RFC_LOGON_FAILED profile_ambiguous=$Profile"; exit 2 }
    $c = $cands[0]
    $pw = (& (Join-Path $scripts 'sap_dpapi.ps1') -Action unprotect -Value "$($c.password_dpapi)" 2>$null) -as [string]
    try { $d = Connect-SapRfc -Server $c.application_server -Sysnr $c.system_number -MessageServer $c.message_server -LogonGroup $c.logon_group -SystemID $c.system_id -Client $c.client -User $c.user -Password $pw -Language $c.language -DestName ("WF_"+$c.system_name) } catch { }
} else {
    try { $d = Connect-SapRfc -DestName 'WF' } catch { }
}
if (-not $d) { Write-Host 'STATUS: BLOCKED rfc_unavailable (run /sap-doctor)'; exit 2 }

try {
# =============================================================================
if ($Mode -eq 'diagnose') {
    # --- build SWWWIHEAD selection from anchors --------------------------------
    $w = @()
    if ($WiId) { $w += "WI_ID = '$($WiId.PadLeft(12,'0'))'" }
    if ($Task) { $w += "WI_RH_TASK = '$($Task.ToUpper())'" }
    if ($User) { $w += "WI_AAGENT = '$($User.ToUpper())'" }
    if ($Status -and $Status.ToLower() -ne 'all') { $w += "WI_STAT = 'ERROR'" }
    if ($Since) { $w += "WI_CD GE '$Since'" }
    $where = ($w -join ' AND ')
    $rows = @(Read-Rows $d 'SWWWIHEAD' $where @('WI_ID','WI_TYPE','WI_STAT','WI_RH_TASK','WI_RHTEXT','WI_TEXT','WI_CD','WI_AAGENT','TOP_WI_ID') ([Math]::Max(1,$Top)))
    Write-Host ("WFSEL: matched=$($rows.Count) where=`"$where`" top=$Top")
    $errCount=0; $agentGap=0
    foreach ($r in $rows) {
        $wi=(San $r.WI_ID); $st=(San $r.WI_STAT); $ty=(San $r.WI_TYPE); $tk=(San $r.WI_RH_TASK)
        $emsg=''
        if ($st -eq 'ERROR') {
            $errCount++
            $lh = @(Read-Rows $d 'SWWLOGHIST' "WI_ID = '$wi'" @('LOG_COUNT','MSGTYPE','WORKAREA','MESSAGE','VARIABLE1','VARIABLE2','ERRORTYPE') 50)
            $err = @($lh | Where-Object { $_.MSGTYPE -in @('E','A','X') -or [int]("0"+$_.ERRORTYPE) -gt 0 } | Sort-Object { [int]("0"+$_.LOG_COUNT) } -Descending | Select-Object -First 1)
            if ($err.Count) { $mt = Msg-Text $d (San $err[0].WORKAREA) (San $err[0].MESSAGE); $emsg = "$(San $err[0].WORKAREA)-$(San $err[0].MESSAGE) $(San $err[0].MSGTYPE): $mt [$(San $err[0].VARIABLE1)]" }
        }
        # agent-determination gap: a READY dialog WI (type W) with no actual agent
        $flag=''
        if ($st -eq 'READY' -and $ty -eq 'W' -and -not (San $r.WI_AAGENT)) { $flag='AGENT_DETERMINATION'; $agentGap++ }
        Write-Host ("WF: wi=$wi type=$ty stat=$st task=$tk top=$(San $r.TOP_WI_ID) agent=$(San $r.WI_AAGENT) flag=$flag err=`"$emsg`" text=`"$(San $r.WI_RHTEXT)`"")
    }
    # --- environment health ----------------------------------------------------
    $q = @(Read-Rows $d 'SWEQUEUE' '' @('STATUS','RETRIED','EVENT') 2000)
    $qStuck = @($q | Where-Object { [int]("0"+$_.RETRIED) -gt 0 }).Count
    Write-Host ("WFENV: event_queue_rows=$($q.Count) with_retries=$qStuck")
    $lk = @(Read-Rows $d 'SWETYPECOU' '' @('OBJTYPE','EVENT','RECTYPE','GLOBAL','ENABLED') 5000)
    $lkOff = @($lk | Where-Object { (San $_.GLOBAL) -ne 'X' }).Count
    Write-Host ("WFENV: type_linkages=$($lk.Count) inactive=$lkOff")
    $wfb = @(Read-Rows $d 'USR02' "BNAME = 'WF-BATCH'" @('BNAME','UFLAG') 1)
    $wfbState = if ($wfb.Count) { if ((San $wfb[0].UFLAG) -eq '0') { 'active' } else { "locked(UFLAG=$(San $wfb[0].UFLAG))" } } else { 'COULD_NOT_CHECK' }
    Write-Host ("WFENV: wf_batch=$wfbState  swu3_full=COULD_NOT_CHECK(manual SWU3)")
    Write-Host ("STATUS: OK matched=$($rows.Count) errors=$errCount agent_gaps=$agentGap")
    Disconnect-SapRfc; exit 0
}
# =============================================================================
elseif ($Mode -eq 'explain') {
    $otype=''; $objid=''
    if ($Task) { $t=$Task.ToUpper(); if ($t -match '^(TS|WS)(\d+)$') { $otype=$matches[1]; $objid=$matches[2].PadLeft(8,'0') } else { Write-Host "STATUS: WF_INPUT bad_task=$Task"; Disconnect-SapRfc; exit 2 } }
    elseif ($WiId) {
        $h = @(Read-Rows $d 'SWWWIHEAD' "WI_ID = '$($WiId.PadLeft(12,'0'))'" @('WI_RH_TASK') 1)
        if (-not $h.Count) { Write-Host "STATUS: WF_WI_NOT_FOUND wi=$WiId"; Disconnect-SapRfc; exit 1 }
        $t=(San $h[0].WI_RH_TASK); if ($t -match '^(TS|WS)(\d+)$') { $otype=$matches[1]; $objid=$matches[2].PadLeft(8,'0') }
    } else { Write-Host 'STATUS: WF_INPUT no_task_or_wi'; Disconnect-SapRfc; exit 2 }
    # task text (logon lang first, then E, then any)
    $txt=''; $short=''
    foreach ($lang in @('E','D','1')) { $tt = @(Read-Rows $d 'HRS1000' "OTYPE = '$otype' AND OBJID = '$objid' AND LANGU = '$lang'" @('SHORT','STEXT') 1); if ($tt.Count) { $short=(San $tt[0].SHORT); $txt=(San $tt[0].STEXT); break } }
    if (-not $txt) { $tt = @(Read-Rows $d 'HRS1000' "OTYPE = '$otype' AND OBJID = '$objid'" @('SHORT','STEXT') 1); if ($tt.Count) { $short=(San $tt[0].SHORT); $txt=(San $tt[0].STEXT) } }
    Write-Host ("WFEXPL: task=$otype$objid short=`"$short`" text=`"$txt`"")
    # definition status (WS only, best-effort: WFD_ID == objid)
    if ($otype -eq 'WS') {
        $hd = @(Read-Rows $d 'SWDSHEADER' "WFD_ID = '$otype$objid'" @('VERSION','STATUS','ACTIV','SUSPEND_E','CHANGED_BY','CHANGED_ON') 20)
        $act = @($hd | Where-Object { (San $_.ACTIV) -eq 'X' } | Select-Object -First 1)
        if ($act.Count) { Write-Host ("WFEXPL: definition version=$(San $act[0].VERSION) status=$(San $act[0].STATUS) active=X suspend_exec=$(San $act[0].SUSPEND_E) changed_by=$(San $act[0].CHANGED_BY)/$(San $act[0].CHANGED_ON)") }
        elseif ($hd.Count) { Write-Host ("WFEXPL: definition versions=$($hd.Count) active=none COULD_NOT_CHECK(no active version row)") }
        else { Write-Host ("WFEXPL: definition COULD_NOT_CHECK(no SWDSHEADER WFD_ID=$objid)") }
    }
    # triggering events (this task is the receiver)
    $ev = @(Read-Rows $d 'SWETYPECOU' "RECTYPE = '$otype$objid'" @('OBJTYPE','EVENT','GLOBAL','ENABLED') 200)
    Write-Host ("WFEXPL: triggering_events=$($ev.Count)")
    foreach ($e in $ev) { Write-Host ("WFEVENT: objtype=$(San $e.OBJTYPE) event=$(San $e.EVENT) linkage_active=$(if((San $e.GLOBAL) -eq 'X'){'YES'}else{'NO'})") }
    Write-Host ("STATUS: OK task=$otype$objid events=$($ev.Count)")
    Disconnect-SapRfc; exit 0
}
# =============================================================================
elseif ($Mode -eq 'act') {
    if (-not $WiId) { Write-Host 'STATUS: WF_INPUT no_wiid'; Disconnect-SapRfc; exit 2 }
    if ($Verb -notin @('restart','cancel','forward')) { Write-Host "STATUS: WF_INPUT bad_verb=$Verb"; Disconnect-SapRfc; exit 2 }
    $wi = $WiId.PadLeft(12,'0')
    $pre = @(Read-Rows $d 'SWWWIHEAD' "WI_ID = '$wi'" @('WI_ID','WI_TYPE','WI_STAT','WI_RH_TASK','WI_RHTEXT','TOP_WI_ID') 1)
    if (-not $pre.Count) { Write-Host "STATUS: WF_WI_NOT_FOUND wi=$wi"; Disconnect-SapRfc; exit 1 }
    $st=(San $pre[0].WI_STAT); $ty=(San $pre[0].WI_TYPE); $top=(San $pre[0].TOP_WI_ID); $tk=(San $pre[0].WI_RH_TASK)
    Write-Host ("WFACT: pre wi=$wi type=$ty stat=$st task=$tk top=$top text=`"$(San $pre[0].WI_RHTEXT)`"")
    # --- refusal matrix (refuse BEFORE any write / before the SKILL.md confirm) --
    $reason=''
    switch ($Verb) {
        'restart' { if ($st -ne 'ERROR') { $reason="restart requires WI_STAT=ERROR (is $st)" }; $target=$top }
        'cancel'  { if ($st -in @('COMPLETED','CANCELLED')) { $reason="cannot cancel a $st workitem" }; $target=$wi }
        'forward' { if (-not $To) { $reason='forward requires -To USER' } elseif ($ty -ne 'W') { $reason="forward is for dialog (W) workitems (is type $ty)" }; $target=$wi }
    }
    if ($reason) { Write-Host ("WFACT: REFUSED verb=$Verb reason=`"$reason`""); Write-Host "STATUS: WF_ACT_INVALID_STATE $reason"; Disconnect-SapRfc; exit 1 }
    $target = ("$target").Trim().PadLeft(12,'0')
    if ($DryRun) { Write-Host ("WFACT: DRYRUN verb=$Verb target=$target would_call=$(switch($Verb){'restart'{'SAP_WAPI_ADM_WORKFLOW_RESTART'}'cancel'{'SAP_WAPI_ADM_WORKFLOW_CANCEL'}'forward'{'SAP_WAPI_FORWARD_WORKITEM'}})"); Write-Host "STATUS: OK dryrun"; Disconnect-SapRfc; exit 0 }
    # --- execute the released WAPI write API (mutation) -------------------------
    $rc = -1; $fmName=''
    if ($Verb -eq 'restart') { $fmName='SAP_WAPI_ADM_WORKFLOW_RESTART'; $f=$d.Repository.CreateFunction($fmName); $f.SetValue('WORKITEM_ID',$target); try { $f.SetValue('DO_COMMIT','X') } catch {}; $f.Invoke($d); $rc=[int]$f.GetValue('RETURN_CODE') }
    elseif ($Verb -eq 'cancel') { $fmName='SAP_WAPI_ADM_WORKFLOW_CANCEL'; $f=$d.Repository.CreateFunction($fmName); $f.SetValue('WORKITEM_ID',$target); try { $f.SetValue('DO_COMMIT','X') } catch {}; $f.Invoke($d); $rc=[int]$f.GetValue('RETURN_CODE') }
    elseif ($Verb -eq 'forward') { $fmName='SAP_WAPI_FORWARD_WORKITEM'; $f=$d.Repository.CreateFunction($fmName); $f.SetValue('WORKITEM_ID',$target); $ut=$f.GetTable('USER_IDS'); $ut.Append(); $ut.SetValue('USER',$To.ToUpper()); try { $f.SetValue('DO_COMMIT','X') } catch {}; $f.Invoke($d); $rc=[int]$f.GetValue('RETURN_CODE') }
    Write-Host ("WFACT: called fm=$fmName rc=$rc")
    # --- authoritative re-read verify ------------------------------------------
    $post = @(Read-Rows $d 'SWWWIHEAD' "WI_ID = '$wi'" @('WI_STAT') 1)
    $newSt = if ($post.Count) { San $post[0].WI_STAT } else { '?' }
    Write-Host ("WFACT: verify wi=$wi old_stat=$st new_stat=$newSt rc=$rc")
    if ($rc -eq 0 -and $newSt -ne $st) { Write-Host "STATUS: OK verb=$Verb $st->$newSt"; Disconnect-SapRfc; exit 0 }
    elseif ($rc -eq 0) { Write-Host "STATUS: WF_ACT_FAILED rc=0_but_status_unchanged stat=$newSt"; Disconnect-SapRfc; exit 1 }
    else { Write-Host "STATUS: WF_ACT_FAILED rc=$rc"; Disconnect-SapRfc; exit 1 }
}
else { Write-Host "STATUS: WF_INPUT bad_mode=$Mode"; Disconnect-SapRfc; exit 2 }
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
