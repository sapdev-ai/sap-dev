# =============================================================================
# sap_idoc_read.ps1  -  IDoc find + explain for /sap-idoc (read-only RFC)
#
# find    : bounded EDIDC search (status / message type / partner / date window /
#           docnum), current status + resolved status text (TEDS2) + severity, per
#           status+mestyp counts. Refuses an unbounded scan.
# explain : full EDIDS status history for one DOCNUM (ordered), each step with its
#           authoritative severity (EDIDS-STATYP), message id (STAMID-STAMNO),
#           parameters and rendered text (STATXT), plus the EDIDC header.
#
#   -Action find      [-Dir 1|2] [-Status 51,56] [-Mestyp M] [-Partner P]
#                     [-From YYYYMMDD] [-To YYYYMMDD] [-Max 500] [-OutTsv PATH]
#   -Action explain   -Docnum <DOCNUM>
#
# READ-ONLY. RFC_READ_TABLE only (EDIDC/EDIDS/TEDS2 all TRANSP/FMODE=R, probed
# identical S4D + EC2 2026-07-11). EDID4 is NEVER read (CLUSTER on ECC; segment
# decode is the wrapper-based v1.5 path). Field names identical on ECC 6 / S/4.
#
# Output (stdout, parseable by SKILL.md):
#   find:
#     IDOC:  docnum=<n> dir=<1|2> status=<s> sev=<E|W|S|I> mestyp=<m> idoctp=<t>
#            partner=<snd|rcv> credat=<d> text="<status text>"
#     COUNT: status=<s> sev=<..> n=<n>
#     STATUS: OK rows=<n|">Max"> capped=<Y|N> | IDOC_SELECTION_UNBOUNDED | RFC_ERROR
#   explain:
#     HEADER: docnum=<n> dir=<1|2> mestyp=<m> idoctp=<t> status=<s> snd=<p> rcv=<p> credat=<d>
#     STEP:   seq=<n> status=<s> sev=<E|W|S|I> msg=<id-no> parm=<p1> text="<..>" date=<d> time=<t>
#     STATUS: OK steps=<n> | IDOC_NOT_FOUND | RFC_ERROR
# Exit: 0 = OK | 1 = not found / unbounded | 2 = connect failure.
# =============================================================================

[CmdletBinding()]
param(
    [ValidateSet('find','explain')]
    [string]   $Action = 'find',
    [string]   $Dir = '',
    [string]   $Status = '',
    [string]   $Mestyp = '',
    [string]   $Partner = '',
    [string]   $From = '',
    [string]   $To = '',
    [int]      $Max = 500,
    [string]   $Docnum = '',
    [string]   $OutTsv = '',
    [string]   $SharedDir = '',
    [string]   $SkillDir = '',
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

$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_object_resolver.ps1','sap_artifact_lib.ps1') {
    $p = Join-Path $scripts $lib
    if (Test-Path $p) { . $p }
}
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function San { param([string] $s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Qz  { param([string] $s) return ((San $s) -replace '"', "'") }

# Standard IDoc status severity (find uses this fast map; explain uses the
# authoritative per-row EDIDS-STATYP). Customer status extensions default to 'I'.
$ERR = @('02','04','05','25','26','29','32','40','51','56','60','61','63','65','68','69')
$OK  = @('03','12','16','18','38','39','41','53')
function Sev-Of { param([string] $s) $s = (San $s); if ($ERR -contains $s) { 'E' } elseif ($OK -contains $s) { 'S' } else { 'I' } }
function Sev-StaTyp { param([string] $t) switch ((San $t)) { 'E' { 'E' } 'A' { 'E' } 'W' { 'W' } 'S' { 'S' } default { 'I' } } }

function Write-Tsv { param([string] $Path, [string] $Header, [object[]] $Lines)
    $sb = New-Object System.Text.StringBuilder; [void]$sb.AppendLine($Header)
    foreach ($l in $Lines) { [void]$sb.AppendLine($l) }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}

# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {

    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer `
                             -LogonGroup $LogonGroup -SystemID $SystemID `
                             -Client $Client -User $UserId -Password $Password -Language $Language `
                             -DestName "SAPDEV_IDOC"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }
    $lang = if ($Language) { $Language } else { 'E' }

    # status-text map (TEDS2 for the logon language)
    function Get-StatusTextMap {
        $m = @{}
        try {
            $rows = Read-SapTableRows -Destination $g_dest -Table 'TEDS2' -Where "LANGUA EQ '$lang'" -Fields @('STATUS','DESCRP') -RowCount 500
            foreach ($r in @($rows)) { $m[(San $r.STATUS)] = (San $r.DESCRP) }
        } catch { }
        return $m
    }

    try {
        if ($Action -eq 'explain') {
            if (-not $Docnum) { Write-Host "STATUS: IDOC_NOT_FOUND reason=no_docnum"; Disconnect-SapRfc; exit 1 }
            $doc = (San $Docnum); if ($doc -match '^\d+$') { $doc = $doc.PadLeft(16, '0') }
            $hdr = Read-SapTableRows -Destination $g_dest -Table 'EDIDC' -Where "DOCNUM EQ '$doc'" -Fields @('DOCNUM','DIRECT','MESTYP','IDOCTP','STATUS','SNDPRN','RCVPRN','CREDAT') -RowCount 1
            if (-not @($hdr).Count) { Write-Host "STATUS: IDOC_NOT_FOUND docnum=$doc"; Disconnect-SapRfc; exit 1 }
            $h = $hdr[0]; $dir = San $h.DIRECT
            $partner = if ($dir -eq '1') { San $h.RCVPRN } else { San $h.SNDPRN }
            Write-Host ("HEADER: docnum={0} dir={1} mestyp={2} idoctp={3} status={4} snd={5} rcv={6} credat={7}" -f (San $h.DOCNUM),$dir,(San $h.MESTYP),(San $h.IDOCTP),(San $h.STATUS),(San $h.SNDPRN),(San $h.RCVPRN),(San $h.CREDAT))

            $stMap = Get-StatusTextMap
            $steps = Read-SapTableRows -Destination $g_dest -Table 'EDIDS' -Where "DOCNUM EQ '$doc'" -Fields @('LOGDAT','LOGTIM','COUNTR','STATUS','STATYP','STAMID','STAMNO','STAPA1','STATXT') -RowCount 200
            # order by LOGDAT, LOGTIM, COUNTR
            $ordered = @($steps) | Sort-Object @{Expression={ "$($_.LOGDAT)$($_.LOGTIM)" + ('{0:D6}' -f [int]("0"+(San $_.COUNTR))) }}
            $seq = 0
            foreach ($s in $ordered) {
                $seq++
                $st = San $s.STATUS; $sev = Sev-StaTyp $s.STATYP; if ($sev -eq 'I' -and (Sev-Of $st) -eq 'E') { $sev = 'E' }
                $txt = San $s.STATXT; if (-not $txt) { $txt = $stMap[$st] }
                $mid = San $s.STAMID; $mno = San $s.STAMNO
                $msg = if ($mid) { "$mid-$mno" } else { '-' }
                Write-Host ("STEP: seq={0} status={1} sev={2} msg={3} parm={4} text=`"{5}`" date={6} time={7}" -f $seq,$st,$sev,$msg,(San $s.STAPA1),(Qz $txt),(San $s.LOGDAT),(San $s.LOGTIM))
            }
            Write-Host ("STATUS: OK steps=$seq")
            Disconnect-SapRfc; exit 0
        }

        # ---- find --------------------------------------------------------
        $clauses = @()
        if ($Docnum) { $d = (San $Docnum); if ($d -match '^\d+$') { $d = $d.PadLeft(16,'0') }; $clauses += "DOCNUM EQ '$d'" }
        if ($Dir)    { $clauses += "DIRECT EQ '$(San $Dir)'" }
        if ($Status) { $sts = @(($Status -split '[, ]+') | Where-Object { $_ }); $or = ($sts | ForEach-Object { "STATUS EQ '$(San $_)'" }) -join ' OR '; if ($sts.Count -eq 1) { $clauses += "STATUS EQ '$(San $sts[0])'" } else { $clauses += "( $or )" } }
        if ($Mestyp) { $clauses += "MESTYP EQ '$(San $Mestyp)'" }
        if ($Partner){ $clauses += "( SNDPRN EQ '$(San $Partner)' OR RCVPRN EQ '$(San $Partner)' )" }
        if ($From)   { $clauses += "CREDAT GE '$(San $From)'" }
        if ($To)     { $clauses += "CREDAT LE '$(San $To)'" }

        if (-not $clauses.Count) { Write-Host "STATUS: IDOC_SELECTION_UNBOUNDED reason=need_status_mestyp_partner_date_or_docnum"; Disconnect-SapRfc; exit 1 }

        $stMap = Get-StatusTextMap
        $rows = Read-SapTableRows -Destination $g_dest -Table 'EDIDC' -Where ($clauses -join ' AND ') -Fields @('DOCNUM','DIRECT','STATUS','MESTYP','IDOCTP','SNDPRN','RCVPRN','CREDAT') -RowCount ($Max + 1)
    $all = @($rows)
        $capped = ($all.Count -gt $Max)
        if ($capped) { $all = $all[0..($Max-1)] }
        $tsvLines = @(); $counts = @{}
        foreach ($r in $all) {
            $st = San $r.STATUS; $dir = San $r.DIRECT; $sev = Sev-Of $st
            $partner = if ($dir -eq '1') { San $r.RCVPRN } else { San $r.SNDPRN }
            $txt = $stMap[$st]
            $mestyp = San $r.MESTYP
            Write-Host ("IDOC: docnum={0} dir={1} status={2} sev={3} mestyp={4} idoctp={5} partner={6} credat={7} text=`"{8}`"" -f (San $r.DOCNUM),$dir,$st,$sev,$mestyp,(San $r.IDOCTP),$partner,(San $r.CREDAT),(Qz $txt))
            $tsvLines += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f (San $r.DOCNUM),$dir,$st,$sev,$mestyp,(San $r.IDOCTP),$partner,(San $r.CREDAT))
            $ck = "$st|$mestyp"; if (-not $counts.ContainsKey($ck)) { $counts[$ck] = @{ st=$st; sev=$sev; mestyp=$mestyp; n=0 } }; $counts[$ck].n++
        }
        foreach ($c in ($counts.Values | Sort-Object -Property @{Expression={$_.n};Descending=$true})) {
            Write-Host ("COUNT: status={0} sev={1} mestyp={2} n={3}" -f $c.st,$c.sev,$c.mestyp,$c.n)
        }
        if ($OutTsv) { try { Write-Tsv $OutTsv "docnum`tdir`tstatus`tsev`tmestyp`tidoctp`tpartner`tcredat" $tsvLines; Write-Host "OUT_TSV: $OutTsv" } catch { } }
        $rowsStr = if ($capped) { ">$Max" } else { "$($all.Count)" }
        Write-Host ("STATUS: OK rows=$rowsStr capped=$(if($capped){'Y'}else{'N'})")
        Disconnect-SapRfc; exit 0
    } catch {
        Write-Host ("ERROR: {0}" -f (San $_.Exception.Message))
        Write-Host "STATUS: RFC_ERROR"
        Disconnect-SapRfc; exit 2
    }
}
