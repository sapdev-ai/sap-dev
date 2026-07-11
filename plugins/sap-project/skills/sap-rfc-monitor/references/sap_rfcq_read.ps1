# =============================================================================
# sap_rfcq_read.ps1  -  tRFC / qRFC queue reader for /sap-rfc-monitor
#
# Read-only snapshot of the RFC queues (the SM58 / SMQ1 / SMQ2 view) over pure
# RFC. Per-queue DEPTH comes SERVER-SIDE from the queue-inspection FMs (never a
# table scan): TRFC_QIN_GET_CURRENT_QUEUES / TRFC_QOUT_GET_CURRENT_QUEUES return
# QVIEW rows (QDEEP/QSTATE/ERRMESS). Head-blocker LUW detail is read per blocked
# queue (TRFC_GET_QIN_INFO_DETAILS inbound; TRFCQOUT rows outbound). The tRFC
# "SM58" view groups ARFCSSTATE by destination x state. QIWKTAB supplies the
# inbound-scheduler registration flag so a backed-up-but-unregistered queue is
# classified NOT_REGISTERED (SMQR pointer) instead of getting a futile retry hint.
#
#   -Area  trfc | qin | qout | qstate | all   (default all)
#   -Dest  <D>        filter by destination      -Queue <Q>  filter by queue name
#   -Top   <n>        cap queues / dest-state clusters (default 20)
#   -HeadLuws <n>     head LUW rows per blocked queue (default 5)
#   -ExpectCleared    RETRY VERIFIER: count still-failed tRFC LUWs for -Dest;
#                     exit 0 + "CLEARED n=0" iff none remain, else exit 3.
#   -OutTsv <path>    also write the snapshot as a TSV.
#
# READ-ONLY. Queue FMs are FMODE=R inspectors; ARFCSSTATE/TRFCQ* read via
# RFC_READ_TABLE. Never mutates queue state (retry is a separate report run,
# delegated by SKILL.md to /sap-run-report). All field names + FM signatures
# probed identical on S4D (S/4HANA 1909) and EC2 (ECC 6) 2026-07-11.
#
# Output (stdout, parseable by SKILL.md):
#   QUEUE: dir=<qin|qout> name=<q> dest=<d> depth=<n> state=<s> registered=<Y|N|->
#          err="<head err>" age_min=<n|->
#   TRFC:  dest=<d> state=<s> luws=<n> fm=<fm> err="<msg>" age_min=<n|->
#   LUW:   dir=<..> ref=<q|dest> fm=<fm> state=<s> retries=<n> err="<msg>"
#   STATUS: OK|RFC_ERROR|COULD_NOT_CHECK qin=<n> qout=<n> trfc=<n> reg_gaps=<n>
# Exit: 0 = OK (incl. ExpectCleared CLEARED) | 2 = connect failure |
#       3 = ExpectCleared NOT_CLEARED.
# =============================================================================

[CmdletBinding()]
param(
    [ValidateSet('trfc','qin','qout','qstate','all')]
    [string]   $Area = 'all',
    [string]   $Dest = '',
    [string]   $Queue = '',
    [int]      $Top = 20,
    [int]      $HeadLuws = 5,
    [switch]   $ExpectCleared,
    [int]      $MaxRows = 2000,
    [string]   $SharedDir = '',
    [string]   $SkillDir = '',
    [string]   $OutTsv = '',
    [string]   $RunId = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $SharedDir) {
    try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' }
}
if (-not $SkillDir) { $SkillDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
$scripts = Join-Path $SharedDir 'scripts'

# preserve our credential params across the dot-sourced libs' own param() blocks
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_object_resolver.ps1','sap_artifact_lib.ps1') {
    $p = Join-Path $scripts $lib
    if (Test-Path $p) { . $p }
}
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

# --- helpers ---------------------------------------------------------------
function San { param([string] $s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }

# CHAR(50/73) SAP error text -> single-line, quote-safe.
function Msg { param([string] $s) $t = (San $s); return ($t -replace '"', "'") }

# DATS + TIMS -> age in whole minutes (>=0), or -1 when unparseable / empty.
function Age-Min {
    param([string] $dats, [string] $tims)
    $d = (San $dats); $t = (San $tims)
    if (-not $d -or $d -eq '00000000') { return -1 }
    if (-not $t) { $t = '000000' }
    $t = ($t + '000000').Substring(0, 6)
    try {
        $dt = [datetime]::ParseExact($d + $t, 'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
        $m = [int]((Get-Date) - $dt).TotalMinutes
        if ($m -lt 0) { return 0 } else { return $m }
    } catch { return -1 }
}

# UTF-8 BOM TSV writer (Excel-friendly, matches the shared finding/artifact libs).
function Write-Tsv {
    param([string] $Path, [string] $Header, [object[]] $Lines)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($Header)
    foreach ($l in $Lines) { [void]$sb.AppendLine($l) }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}

# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {

    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer `
                             -LogonGroup $LogonGroup -SystemID $SystemID `
                             -Client $Client -User $UserId -Password $Password -Language $Language `
                             -DestName "SAPDEV_RFCQ"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }

    $tsvLines = @()

    try {
        # ---- RETRY VERIFIER (authoritative post-retry re-read) ------------
        # A row in ARFCSSTATE for a destination == a still-pending/failed tRFC
        # LUW (SM58 only holds the not-yet-successfully-sent ones). 0 == cleared.
        if ($ExpectCleared) {
            if (-not $Dest) { Write-Host "STATUS: COULD_NOT_CHECK reason=ExpectCleared_needs_Dest"; Disconnect-SapRfc; exit 2 }
            $esc = $Dest -replace "'", "''"
            $rows = Read-SapTableRows -Destination $g_dest -Table 'ARFCSSTATE' -Where "ARFCDEST EQ '$esc'" -Fields @('ARFCDEST','ARFCLUWCNT') -RowCount $MaxRows
            $n = @($rows).Count
            if ($n -eq 0) { Write-Host "CLEARED n=0 dest=$Dest"; Write-Host "STATUS: OK qin=0 qout=0 trfc=0 reg_gaps=0"; Disconnect-SapRfc; exit 0 }
            else          { Write-Host "NOT_CLEARED n=$n dest=$Dest"; Write-Host "STATUS: OK qin=0 qout=0 trfc=$n reg_gaps=0"; Disconnect-SapRfc; exit 3 }
        }

        $doQin   = ($Area -eq 'all' -or $Area -eq 'qin')
        $doQout  = ($Area -eq 'all' -or $Area -eq 'qout')
        $doTrfc  = ($Area -eq 'all' -or $Area -eq 'trfc')
        $doQstate= ($Area -eq 'qstate')
        $cQin = 0; $cQout = 0; $cTrfc = 0; $regGaps = 0; $trfcCapped = $false

        # ---- inbound-scheduler registration set (QIWKTAB) -----------------
        # A QNAME present here is registered for automatic inbound processing.
        $registered = @{}
        try {
            $qi = Read-SapTableRows -Destination $g_dest -Table 'QIWKTAB' -Fields @('TYPE','QNAME','WKSTATE') -RowCount $MaxRows
            foreach ($r in $qi) { $qn = (San $r.QNAME); if ($qn) { $registered[$qn] = (San $r.WKSTATE) } }
        } catch { }  # auth-blocked QIWKTAB -> registration reported as '-' (unknown), never 'N'

        # ---- inbound queues (SMQ2 view) -----------------------------------
        if ($doQin) {
            try {
                $f = $g_dest.Repository.CreateFunction('TRFC_QIN_GET_CURRENT_QUEUES')
                $f.SetValue('NOLUWCNT', '')            # '' = compute QDEEP (depth)
                if ($Queue) { $f.SetValue('QNAME', $Queue) }
                $f.Invoke($g_dest)
                $qv = $f.GetTable('QVIEW')
                $rows = @()
                for ($i = 0; $i -lt $qv.RowCount; $i++) {
                    $qv.CurrentIndex = $i
                    $rows += [pscustomobject]@{
                        QNAME=(San $qv.GetValue('QNAME')); DEST=(San $qv.GetValue('DEST'))
                        QDEEP=[int]("0"+(San $qv.GetValue('QDEEP'))); QSTATE=(San $qv.GetValue('QSTATE'))
                        ERRMESS=(Msg $qv.GetValue('ERRMESS')); FDATE=(San $qv.GetValue('FDATE')); FTIME=(San $qv.GetValue('FTIME'))
                    }
                }
                if ($Dest) { $rows = $rows | Where-Object { $_.DEST -eq $Dest } }
                # deepest / most-stuck first
                $rows = $rows | Sort-Object -Property @{Expression='QDEEP';Descending=$true} | Select-Object -First $Top
                foreach ($r in $rows) {
                    $cQin++
                    $reg = if ($registered.ContainsKey($r.QNAME)) { 'Y' } elseif ($registered.Count) { 'N' } else { '-' }
                    if ($reg -eq 'N') { $regGaps++ }
                    # Read head-blocker LUWs FIRST (TRFC_GET_QIN_INFO_DETAILS carries the
                    # per-LUW FM/state/err + date/time the QVIEW row often leaves blank),
                    # then backfill queue state/age from the head LUW before emitting.
                    $headLines = @(); $qState = $r.QSTATE; $qAge = -1
                    if ($r.QDEEP -gt 0 -and $HeadLuws -gt 0) {
                        try {
                            $d = $g_dest.Repository.CreateFunction('TRFC_GET_QIN_INFO_DETAILS')
                            $d.SetValue('QNAME', $r.QNAME); $d.Invoke($g_dest)
                            $qt = $d.GetTable('QTABLE'); $lim = [Math]::Min($HeadLuws, $qt.RowCount)
                            for ($k = 0; $k -lt $lim; $k++) {
                                $qt.CurrentIndex = $k
                                $lfm = San $qt.GetValue('QRFCFNAM'); $lst = San $qt.GetValue('QSTATE')
                                if ($k -eq 0) { if (-not $qState) { $qState = $lst }; $qAge = Age-Min $qt.GetValue('QRFCDATUM') $qt.GetValue('QRFCUZEIT') }
                                $headLines += ("LUW: dir=qin ref={0} fm={1} state={2} retries={3} err=`"{4}`"" -f $r.QNAME,$lfm,$lst,(San $qt.GetValue('RETRYNR')),(Msg $qt.GetValue('ERRMESS')))
                            }
                        } catch { }
                    }
                    if ($qAge -lt 0) { $qAge = Age-Min $r.FDATE $r.FTIME }
                    Write-Host ("QUEUE: dir=qin name={0} dest={1} depth={2} state={3} registered={4} err=`"{5}`" age_min={6}" -f $r.QNAME,$r.DEST,$r.QDEEP,$qState,$reg,$r.ERRMESS,$qAge)
                    $tsvLines += ("qin`t{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $r.QNAME,$r.DEST,$r.QDEEP,$qState,$reg,$qAge,$r.ERRMESS)
                    $headLines | ForEach-Object { Write-Host $_ }
                }
            } catch { Write-Host ("QUEUE: dir=qin COULD_NOT_CHECK err=`"{0}`"" -f (Msg $_.Exception.Message)) }
        }

        # ---- outbound queues (SMQ1 view) ----------------------------------
        if ($doQout) {
            try {
                $f = $g_dest.Repository.CreateFunction('TRFC_QOUT_GET_CURRENT_QUEUES')
                $f.SetValue('NOLUWCNT', '')
                if ($Dest)  { $f.SetValue('DEST', $Dest) }
                if ($Queue) { $f.SetValue('QNAME', $Queue) }
                $f.Invoke($g_dest)
                $qv = $f.GetTable('QVIEW')
                $rows = @()
                for ($i = 0; $i -lt $qv.RowCount; $i++) {
                    $qv.CurrentIndex = $i
                    $rows += [pscustomobject]@{
                        QNAME=(San $qv.GetValue('QNAME')); DEST=(San $qv.GetValue('DEST'))
                        QDEEP=[int]("0"+(San $qv.GetValue('QDEEP'))); QSTATE=(San $qv.GetValue('QSTATE'))
                        ERRMESS=(Msg $qv.GetValue('ERRMESS')); FDATE=(San $qv.GetValue('FDATE')); FTIME=(San $qv.GetValue('FTIME'))
                    }
                }
                $rows = $rows | Sort-Object -Property @{Expression='QDEEP';Descending=$true} | Select-Object -First $Top
                # Outbound per-LUW FM/state/error attribution is NOT drilled here: the
                # sender-side LUW records live in ARFCSSTATE (keyed by TID), which the
                # tRFC section below already clusters by dest x state globally. QVIEW's
                # server-side depth + state + err is the actionable per-queue signal.
                foreach ($r in $rows) {
                    $cQout++
                    $age = Age-Min $r.FDATE $r.FTIME
                    Write-Host ("QUEUE: dir=qout name={0} dest={1} depth={2} state={3} registered=- err=`"{4}`" age_min={5}" -f $r.QNAME,$r.DEST,$r.QDEEP,$r.QSTATE,$r.ERRMESS,$age)
                    $tsvLines += ("qout`t{0}`t{1}`t{2}`t{3}`t-`t{4}`t{5}" -f $r.QNAME,$r.DEST,$r.QDEEP,$r.QSTATE,$age,$r.ERRMESS)
                }
            } catch { Write-Host ("QUEUE: dir=qout COULD_NOT_CHECK err=`"{0}`"" -f (Msg $_.Exception.Message)) }
        }

        # ---- tRFC (SM58 view) + inbound qRFC LUW state (SMQ2 detail) -------
        if ($doTrfc -or $doQstate) {
            $tbl = if ($doQstate) { 'TRFCQSTATE' } else { 'ARFCSSTATE' }
            $lbl = if ($doQstate) { 'qstate' } else { 'trfc' }
            try {
                $where = ''
                if ($Dest) { $esc = $Dest -replace "'", "''"; $where = "ARFCDEST EQ '$esc'" }
                $rows = Read-SapTableRows -Destination $g_dest -Table $tbl -Where $where -Fields @('ARFCDEST','ARFCSTATE','ARFCFNAM','ARFCMSG','ARFCDATUM','ARFCUZEIT','ARFCRETRYS') -RowCount $MaxRows
                if (@($rows).Count -ge $MaxRows) { $trfcCapped = $true }
                # cluster by (dest, state): count, sample fm/err, oldest age
                $grp = @{}
                foreach ($r in @($rows)) {
                    $key = "$(San $r.ARFCDEST)|$(San $r.ARFCSTATE)"
                    if (-not $grp.ContainsKey($key)) { $grp[$key] = [pscustomobject]@{ Dest=(San $r.ARFCDEST); State=(San $r.ARFCSTATE); N=0; Fm=(San $r.ARFCFNAM); Err=(Msg $r.ARFCMSG); Age=(Age-Min $r.ARFCDATUM $r.ARFCUZEIT) } }
                    $g = $grp[$key]; $g.N++
                    $a = Age-Min $r.ARFCDATUM $r.ARFCUZEIT
                    if ($a -ge 0 -and ($g.Age -lt 0 -or $a -gt $g.Age)) { $g.Age = $a }   # oldest
                    if (-not $g.Err) { $g.Err = (Msg $r.ARFCMSG) }
                }
                $clusters = $grp.Values | Sort-Object -Property @{Expression='N';Descending=$true} | Select-Object -First $Top
                foreach ($g in $clusters) {
                    $cTrfc += $g.N
                    Write-Host ("TRFC: dest={0} state={1} luws={2} fm={3} err=`"{4}`" age_min={5}" -f $g.Dest,$g.State,$g.N,$g.Fm,$g.Err,$g.Age)
                    $tsvLines += ("$lbl`t{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f $g.Dest,$g.State,$g.N,$g.Fm,$g.Age,$g.Err)
                }
            } catch { Write-Host ("TRFC: COULD_NOT_CHECK err=`"{0}`"" -f (Msg $_.Exception.Message)) }
        }

        if ($OutTsv) {
            try { Write-Tsv $OutTsv "dir`tname_or_dest`tdest_or_state`tdepth_or_luws`tstate`tregistered_or_age`tage_or_err`terr" $tsvLines; Write-Host "OUT_TSV: $OutTsv" } catch { }
        }

        $capStr = if ($trfcCapped) { 'Y' } else { 'N' }
        Write-Host ("STATUS: OK qin=$cQin qout=$cQout trfc=$cTrfc reg_gaps=$regGaps capped=$capStr")
        Disconnect-SapRfc
        exit 0
    } catch {
        Write-Host ("ERROR: {0}" -f (San $_.Exception.Message))
        Write-Host "STATUS: RFC_ERROR"
        Disconnect-SapRfc
        exit 2
    }
}
