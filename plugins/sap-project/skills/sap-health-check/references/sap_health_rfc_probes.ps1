# =============================================================================
# sap_health_rfc_probes.ps1  -  morning-sweep RFC probes for /sap-health-check (read-only)
#
# Six probe families, one connection, pure RFC (RFC_READ_TABLE + the two remote-enabled
# qRFC monitor FMs -- all FMODE=R, probed identical S4D + EC2 2026-07-10):
#   idoc  EDIDC   inbound/outbound error+waiting statuses in window
#   trfc  ARFCSSTATE   pending/failed tRFC LUWs by (dest,state)
#   qrfc  TRFC_QIN/QOUT_GET_CURRENT_QUEUES   inbound/outbound queue depth+state
#   spool TSP02   output requests with a hard/soft finishing error
#   jobs  TBTCO   aborted (STATUS='A') jobs in window, by job-name stem
#   dumps SNAP    ABAP short-dumps in window (SEQNO='000' rows), by (uname,ahost)
#
# Every finding is a coarse FINGERPRINT so the baseline can classify it NEW vs RECURRING.
# An area that can't run (auth/RFC) is COULD_NOT_CHECK -- never a silent healthy.
#
#   -WindowHours N [-Max N] [-IdocMap <tsv>] -OutDir <dir>
#
# stdout:
#   HC: area=<a> fingerprint=<fp> count=<n> severity=<HIGH|MEDIUM|LOW> sample="<..>"
#   HC_AREA: area=<a> coverage=<CHECKED|COULD_NOT_CHECK> findings=<n> total=<n> [reason=..]
#   STATUS: OK | RFC_LOGON_FAILED | RFC_ERROR  window=<from>
# Writes findings.tsv (area/fingerprint/count/severity/coverage/sample). Exit 0/2.
# =============================================================================

[CmdletBinding()]
param(
    [int]    $WindowHours = 24,
    [int]    $Max         = 5000,
    [string] $IdocMap     = '',
    [string] $OutDir      = '',
    [string] $SharedDir   = '',
    [string] $RunId       = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
foreach ($lib in 'sap_connection_lib.ps1','sap_rfc_lib.ps1','sap_object_resolver.ps1') { $pp = Join-Path $scripts $lib; if (Test-Path $pp) { . $pp } }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Invoke-Rfc { param($fn,$d) try { $fn.Invoke($d); return $true } catch { if ("$($_.Exception.Message)" -match 'TABLE_WITHOUT_DATA') { return $false } else { throw } } }

# Direct offset-based reader (delimiter '' + FIELDS OFFSET/LENGTH slicing). Used instead
# of Read-SapTableRows because that helper's '|'-delimiter split MANGLES some tables --
# e.g. ARFCSSTATE collapses thousands of rows into one packed value. Offset parse is
# delimiter-proof and correct at scale (verified 4876 ARFCSSTATE rows). WHERE is split at
# ' AND ' into <=72-char OPTIONS rows.
function Read-Rows { param($d,[string]$table,[string]$where,[string[]]$fields,[int]$max)
    $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''; if ($max -gt 0) { [void]$fn.SetValue('ROWCOUNT',$max) }
    if ($where) { $line=''; foreach ($cl in ($where -split '\s+AND\s+')) { $piece = if ($line -eq '') { $cl } else { "AND $cl" }; if ($line -eq '') { $line=$piece } elseif (($line.Length+1+$piece.Length) -le 72) { $line="$line $piece" } else { Add-RfcOption $fn $line; $line=$piece } }; if ($line) { Add-RfcOption $fn $line } }
    foreach ($f in $fields) { Add-RfcField $fn $f }
    if (-not (Invoke-Rfc $fn $d)) { return @() }
    $fm=$fn.GetTable('FIELDS');$off=@{};$len=@{};for($x=0;$x -lt $fm.RowCount;$x++){$fm.CurrentIndex=$x;$nm=("$($fm.GetString('FIELDNAME'))").Trim();$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
    $dt=$fn.GetTable('DATA');$out=@();for($x=0;$x -lt $dt.RowCount;$x++){$dt.CurrentIndex=$x;$wa="$($dt.GetString('WA'))";$rec=[ordered]@{};foreach($f in $fields){$o=$off[$f];$l=$len[$f];$rec[$f]=if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).Trim()}else{''}};$out+=,([pscustomobject]$rec)}
    return $out   # NOT ',$out' -- callers wrap in @(); the comma-wrap collapses to 1 element under @()
}

# window: date-granularity cutoff (a morning sweep looks at the last day). Uses the
# workstation clock; both test systems and the workstation are China time. Timezone
# slop of <=1 day is acceptable for a health sweep and stated in the report.
$winDays = [Math]::Max(1, [Math]::Ceiling($WindowHours / 24.0))
$cutoff  = (Get-Date).AddDays(-$winDays).ToString('yyyyMMdd')

# default IDoc status classes (direction-aware); TSV override wins.
$idocErr = @{ 'in' = @('51','56','60','61','62','63','65'); 'out' = @('02','04','05','25','26','29','30','32') }
$idocWait = @{ 'in' = @('64','66','69','75'); 'out' = @('03','18','30') }
if ($IdocMap -and (Test-Path $IdocMap)) {
    try {
        $ie=@{'in'=@();'out'=@()}; $iw=@{'in'=@();'out'=@()}
        foreach ($ln in ([IO.File]::ReadAllText($IdocMap,[Text.Encoding]::UTF8).TrimStart([char]0xFEFF) -split "`r`n|`n")) {
            if (-not $ln -or $ln.StartsWith('#') -or $ln.StartsWith('status')) { continue }
            $c = $ln -split "`t"; if ($c.Count -lt 3) { continue }
            $st=$c[0].Trim(); $dir=$c[1].Trim().ToLower(); $cls=$c[2].Trim().ToUpper()
            if ($cls -eq 'ERROR') { $ie[$dir]+=$st } elseif ($cls -eq 'WAITING') { $iw[$dir]+=$st }
        }
        if ($ie['in'].Count -or $ie['out'].Count) { $idocErr=$ie; $idocWait=$iw }
    } catch { }
}

$findings = @()   # each: @{area;fp;count;sev;cov;sample}
function Sev { param([int]$n,[int]$warn,[int]$crit) if ($n -ge $crit) { 'HIGH' } elseif ($n -ge $warn) { 'MEDIUM' } else { 'LOW' } }
function Emit { param($area,$fp,$count,$sev,$sample)
    $script:findings += @{ area=$area; fp=$fp; count=$count; sev=$sev; cov='CHECKED'; sample=(San $sample) }
    Write-Host ("HC: area={0} fingerprint={1} count={2} severity={3} sample=`"{4}`"" -f $area,$fp,$count,$sev,((San $sample) -replace '"',"'"))
}
function Area { param($area,$cov,$nf,$total,$reason)
    Write-Host ("HC_AREA: area={0} coverage={1} findings={2} total={3}{4}" -f $area,$cov,$nf,$total,$(if($reason){" reason=$reason"}else{''}))
    if ($cov -eq 'COULD_NOT_CHECK') { $script:findings += @{ area=$area; fp="$area:COULD_NOT_CHECK"; count=0; sev='LOW'; cov='COULD_NOT_CHECK'; sample=$reason } }
}
function JobStem { param([string]$j) return (($j -replace '[_/-]?\d{4,}.*$','') -replace '\d+$','').Trim('_','/','-') }

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $OutDir) { Write-Host 'STATUS: RFC_ERROR no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$dest = $null; try { $dest = Connect-SapRfc -DestName 'HC_SWEEP' } catch { }
if (-not $dest) { Write-Host 'STATUS: RFC_LOGON_FAILED'; exit 2 }

try {
    # ---- 1. idoc (EDIDC) ------------------------------------------------------
    try {
        $rows = @(Read-Rows $dest 'EDIDC' "CREDAT GE '$cutoff'" @('DOCNUM','DIRECT','STATUS','MESTYP','CREDAT') $Max)
        $grp = @{}
        foreach ($r in $rows) {
            $dir = if ((San $r.DIRECT) -eq '2') { 'in' } else { 'out' }   # 1=outbound,2=inbound
            $st = San $r.STATUS
            $cls = if ($idocErr[$dir] -contains $st) { 'ERROR' } elseif ($idocWait[$dir] -contains $st) { 'WAITING' } else { 'OK' }
            if ($cls -eq 'OK') { continue }
            $k = "idoc:${dir}:$(San $r.MESTYP):$st"; if (-not $grp.ContainsKey($k)) { $grp[$k]=@{n=0;cls=$cls;s=(San $r.MESTYP)} }; $grp[$k].n++
        }
        foreach ($k in $grp.Keys) { $g=$grp[$k]; $sev = if ($g.cls -eq 'ERROR') { Sev $g.n 1 20 } else { 'LOW' }; Emit 'idoc' $k $g.n $sev "$($g.cls) IDocs mestyp=$($g.s)" }
        Area 'idoc' 'CHECKED' $grp.Count $rows.Count ''
    } catch { Area 'idoc' 'COULD_NOT_CHECK' 0 0 'EDIDC_read_failed' }

    # ---- 2. trfc (ARFCSSTATE) -------------------------------------------------
    try {
        $rows = @(Read-Rows $dest 'ARFCSSTATE' '' @('ARFCDEST','ARFCSTATE') $Max)
        $grp = @{}
        foreach ($r in $rows) { $k="trfc:$(San $r.ARFCDEST):$(San $r.ARFCSTATE)"; if (-not $grp.ContainsKey($k)) { $grp[$k]=@{n=0;d=(San $r.ARFCDEST);s=(San $r.ARFCSTATE)} }; $grp[$k].n++ }
        foreach ($k in $grp.Keys) { $g=$grp[$k]; Emit 'trfc' $k $g.n (Sev $g.n 1 50) "dest=$($g.d) state=$($g.s)" }
        Area 'trfc' 'CHECKED' $grp.Count $rows.Count ''
    } catch { Area 'trfc' 'COULD_NOT_CHECK' 0 0 'ARFCSSTATE_read_failed' }

    # ---- 3. qrfc (queue monitor FMs) -----------------------------------------
    foreach ($qdir in @('qin','qout')) {
        try {
            $fmn = if ($qdir -eq 'qin') { 'TRFC_QIN_GET_CURRENT_QUEUES' } else { 'TRFC_QOUT_GET_CURRENT_QUEUES' }
            $f = $dest.Repository.CreateFunction($fmn); $f.SetValue('NOLUWCNT',''); $f.Invoke($dest)
            $qv = $f.GetTable('QVIEW'); $n=0
            for ($i=0;$i -lt $qv.RowCount;$i++){ $qv.CurrentIndex=$i; $qn=(San $qv.GetString('QNAME')); $qd=[int]("0"+(San $qv.GetString('QDEEP'))); $qs=(San $qv.GetString('QSTATE')); if (-not $qn) { continue }; $n++; Emit 'qrfc' "qrfc:${qdir}:$qn" $qd (Sev $qd 1 100) "queue=$qn state=$qs depth=$qd" }
            Area "qrfc.$qdir" 'CHECKED' $n $qv.RowCount ''
        } catch { Area "qrfc.$qdir" 'COULD_NOT_CHECK' 0 0 'queue_fm_failed' }
    }

    # ---- 4. spool (TSP02 finishing errors) -----------------------------------
    try {
        $rows = @(Read-Rows $dest 'TSP02' "PJFINAHERR GT 0" @('PJOWNER','PJDEST','PJSTATUS','PJFINAHERR') $Max)
        $grp = @{}
        foreach ($r in $rows) { $k="spool:$(San $r.PJOWNER):$(San $r.PJDEST)"; if (-not $grp.ContainsKey($k)) { $grp[$k]=@{n=0;o=(San $r.PJOWNER);d=(San $r.PJDEST)} }; $grp[$k].n++ }
        foreach ($k in $grp.Keys) { $g=$grp[$k]; Emit 'spool' $k $g.n (Sev $g.n 1 20) "owner=$($g.o) device=$($g.d) hard-error output requests" }
        Area 'spool' 'CHECKED' $grp.Count $rows.Count ''
    } catch { Area 'spool' 'COULD_NOT_CHECK' 0 0 'TSP02_read_failed' }

    # ---- 5. jobs (TBTCO aborted) ---------------------------------------------
    try {
        $rows = @(Read-Rows $dest 'TBTCO' "STATUS = 'A' AND SDLSTRTDT GE '$cutoff'" @('JOBNAME','JOBCOUNT','STATUS','SDLSTRTDT') $Max)
        $grp = @{}
        foreach ($r in $rows) { $stem=JobStem (San $r.JOBNAME); if (-not $stem) { $stem=(San $r.JOBNAME) }; $k="jobs:$stem"; if (-not $grp.ContainsKey($k)) { $grp[$k]=@{n=0;s=$stem} }; $grp[$k].n++ }
        foreach ($k in $grp.Keys) { $g=$grp[$k]; Emit 'jobs' $k $g.n (Sev $g.n 1 5) "aborted job stem=$($g.s)" }
        Area 'jobs' 'CHECKED' $grp.Count $rows.Count ''
    } catch { Area 'jobs' 'COULD_NOT_CHECK' 0 0 'TBTCO_read_failed' }

    # ---- 6. dumps (SNAP SEQNO='000') -----------------------------------------
    try {
        $rows = @(Read-Rows $dest 'SNAP' "SEQNO = '000' AND DATUM GE '$cutoff'" @('DATUM','UNAME','AHOST') $Max)
        $grp = @{}
        foreach ($r in $rows) { $k="dumps:$(San $r.UNAME):$(San $r.AHOST)"; if (-not $grp.ContainsKey($k)) { $grp[$k]=@{n=0;u=(San $r.UNAME);h=(San $r.AHOST)} }; $grp[$k].n++ }
        foreach ($k in $grp.Keys) { $g=$grp[$k]; Emit 'dumps' $k $g.n (Sev $g.n 1 10) "user=$($g.u) host=$($g.h)" }
        Area 'dumps' 'CHECKED' $grp.Count $rows.Count ''
    } catch { Area 'dumps' 'COULD_NOT_CHECK' 0 0 'SNAP_read_failed' }

    # ---- write findings.tsv --------------------------------------------------
    $lines = @()
    foreach ($f in $findings) { $lines += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f $f.area,$f.fp,$f.count,$f.sev,$f.cov,($f.sample -replace "`t",' ')) }
    $sb = New-Object System.Text.StringBuilder; [void]$sb.AppendLine("area`tfingerprint`tcount`tseverity`tcoverage`tsample")
    foreach ($l in $lines) { [void]$sb.AppendLine($l) }
    [IO.File]::WriteAllText((Join-Path $OutDir 'findings.tsv'), $sb.ToString(), (New-Object Text.UTF8Encoding($true)))

    Write-Host ("STATUS: OK window=$cutoff areas=6 findings=$(@($findings | Where-Object { $_.cov -eq 'CHECKED' }).Count)")
    Disconnect-SapRfc; exit 0
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
