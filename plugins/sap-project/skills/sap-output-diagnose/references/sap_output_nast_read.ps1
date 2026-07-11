# =============================================================================
# sap_output_nast_read.ps1  -  Stages 1-3 of /sap-output-diagnose (read-only RFC)
#
# Resolves an SD billing document (KAPPL=V3) or MM purchase order (KAPPL=EF),
# reads its NAST output-status rows, classifies each (issued OK / processing
# failed / not yet processed), and for a FAILED output pulls the CMFP processing
# log (APLID='WFMC', keyed by NAST-CMFPNR) rendered to text via
# BAPI_MESSAGE_GETDETAIL. TNAPR names the exact print program / form per output.
#
#   -App billing|po   -DocNo <VBELN|EBELN>   [-Kschl <type>]  [-OutJson <path>]
#
# READ-ONLY. RFC_READ_TABLE + BAPI_MESSAGE_GETDETAIL (both FMODE=R, probed on S4D
# + EC2 2026-07-11). Never issues or re-issues output (that is `reissue`, a
# separate gated RSNAST00 run). All field names identical on ECC 6 and S/4HANA.
#
# Output (stdout, parseable by SKILL.md):
#   DOC:  app=<billing|po> docno=<n> exists=<Y|N> type=<FKART|BSART> org=<VKORG|EKORG>
#   NAST: kschl=<t> medium=<NACHA> vstat=<0|1|2> status=<ISSUED_OK|PROCESSING_FAILED|
#         NOT_YET_PROCESSED> cmfpnr=<n> program=<PGNAM|SFORM> dispatch=<VSZTP>
#   LOG:  kschl=<t> sev=<E|W|I> msg="<class-nr: rendered text>"
#   STATUS: OK n_outputs=<n> failed=<n> notyet=<n> | OUTPUT_DOC_NOT_FOUND | RFC_ERROR
# Exit: 0 = OK | 1 = doc not found | 2 = connect failure.
# =============================================================================

[CmdletBinding()]
param(
    [ValidateSet('billing','po')]
    [string]   $App = 'billing',
    [string]   $DocNo = '',
    [string]   $Kschl = '',
    [string]   $OutJson = '',
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

# VSTAT -> verdict token
function Status-Of { param([string] $v)
    switch ((San $v)) { '1' { 'ISSUED_OK' } '2' { 'PROCESSING_FAILED' } '0' { 'NOT_YET_PROCESSED' } default { "VSTAT_$v" } }
}

# Render a T100 message via BAPI_MESSAGE_GETDETAIL (best-effort; returns raw id on failure).
function Get-MsgText {
    param($Destination, [string] $Id, [string] $No, [string] $V1, [string] $V2, [string] $V3, [string] $V4, [string] $Lang)
    if (-not $Id -or -not $No) { return '' }
    try {
        $fn = $Destination.Repository.CreateFunction('BAPI_MESSAGE_GETDETAIL')
        $fn.SetValue('ID', $Id); $fn.SetValue('NUMBER', [int]$No)
        if ($Lang) { $fn.SetValue('LANGUAGE', $Lang) }
        $fn.SetValue('TEXTFORMAT', 'ASC')
        $fn.SetValue('MESSAGE_V1', $V1); $fn.SetValue('MESSAGE_V2', $V2); $fn.SetValue('MESSAGE_V3', $V3); $fn.SetValue('MESSAGE_V4', $V4)
        $fn.Invoke($Destination)
        return (San $fn.GetValue('MESSAGE'))
    } catch { return '' }
}

# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {

    if (-not $DocNo) { Write-Host "STATUS: OUTPUT_DOC_NOT_FOUND reason=no_docno"; exit 1 }
    $kappl = if ($App -eq 'po') { 'EF' } else { 'V3' }
    # normalize a numeric doc to 10-digit ALPHA (VBELN/EBELN); leave alnum as-is
    $doc = (San $DocNo)
    if ($doc -match '^\d+$') { $doc = $doc.PadLeft(10, '0') }

    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer `
                             -LogonGroup $LogonGroup -SystemID $SystemID `
                             -Client $Client -User $UserId -Password $Password -Language $Language `
                             -DestName "SAPDEV_OUTNAST"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }

    $lang = if ($Language) { $Language } else { 'E' }
    $evidence = [ordered]@{ app=$App; docno=$doc; kappl=$kappl; outputs=@() }

    try {
        # ---- Stage 1: document resolve ------------------------------------
        $docExists = $false; $docType = ''; $docOrg = ''
        if ($App -eq 'billing') {
            $h = Read-SapTableRows -Destination $g_dest -Table 'VBRK' -Where "VBELN EQ '$doc'" -Fields @('VBELN','FKART','VKORG','FKSTO') -RowCount 1
            if (@($h).Count) { $docExists = $true; $docType = San $h[0].FKART; $docOrg = San $h[0].VKORG; $evidence.fksto = San $h[0].FKSTO }
        } else {
            $h = Read-SapTableRows -Destination $g_dest -Table 'EKKO' -Where "EBELN EQ '$doc'" -Fields @('EBELN','BSART','EKORG','LIFNR') -RowCount 1
            if (@($h).Count) { $docExists = $true; $docType = San $h[0].BSART; $docOrg = San $h[0].EKORG; $evidence.lifnr = San $h[0].LIFNR }
        }
        Write-Host ("DOC: app={0} docno={1} exists={2} type={3} org={4}" -f $App,$doc,$(if($docExists){'Y'}else{'N'}),$docType,$docOrg)
        $evidence.exists = $docExists; $evidence.type = $docType; $evidence.org = $docOrg
        if (-not $docExists) { Write-Host "STATUS: OUTPUT_DOC_NOT_FOUND docno=$doc"; if ($OutJson) { $evidence | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutJson -Encoding UTF8 }; Disconnect-SapRfc; exit 1 }

        # ---- Stage 2: NAST rows for this document -------------------------
        $where = "KAPPL EQ '$kappl' AND OBJKY LIKE '$doc%'"
        if ($Kschl) { $esc = $Kschl -replace "'", "''"; $where += " AND KSCHL EQ '$esc'" }
        $nast = Read-SapTableRows -Destination $g_dest -Table 'NAST' -Where $where -Fields @('KSCHL','NACHA','VSTAT','CMFPNR','VSZTP','PARVW','ERDAT') -RowCount 50
        $nOut = 0; $nFail = 0; $nNotYet = 0

        foreach ($r in @($nast)) {
            $nOut++
            $ks = San $r.KSCHL; $med = San $r.NACHA; $vstat = San $r.VSTAT; $cmfpnr = San $r.CMFPNR; $vsztp = San $r.VSZTP
            $status = Status-Of $vstat
            if ($status -eq 'PROCESSING_FAILED') { $nFail++ }
            elseif ($status -eq 'NOT_YET_PROCESSED') { $nNotYet++ }

            # TNAPR: print program / form for this KSCHL + medium
            $prog = ''
            try {
                $tn = Read-SapTableRows -Destination $g_dest -Table 'TNAPR' -Where "KAPPL EQ '$kappl' AND KSCHL EQ '$ks' AND NACHA EQ '$med'" -Fields @('PGNAM','SFORM','FONAM') -RowCount 1
                if (@($tn).Count) { $prog = (San $tn[0].PGNAM); if (-not $prog) { $prog = (San $tn[0].SFORM) } }
            } catch { }

            Write-Host ("NAST: kschl={0} medium={1} vstat={2} status={3} cmfpnr={4} program={5} dispatch={6}" -f $ks,$med,$vstat,$status,$cmfpnr,$prog,$vsztp)
            $ev = [ordered]@{ kschl=$ks; medium=$med; vstat=$vstat; status=$status; cmfpnr=$cmfpnr; program=$prog; dispatch=$vsztp; log=@() }

            # ---- Stage 3: processing log for a FAILED output --------------
            if ($status -eq 'PROCESSING_FAILED' -and $cmfpnr -and $cmfpnr -ne '000000000000') {
                try {
                    $msgs = Read-SapTableRows -Destination $g_dest -Table 'CMFP' -Where "APLID EQ 'WFMC' AND NR EQ '$cmfpnr'" -Fields @('MSGCNT','ARBGB','MSGTY','MSGNR','MSGV1','MSGV2','MSGV3','MSGV4') -RowCount 20
                    foreach ($m in @($msgs)) {
                        $sev = San $m.MSGTY; $cls = San $m.ARBGB; $no = San $m.MSGNR
                        if (-not $cls) { continue }
                        $txt = Get-MsgText $g_dest $cls $no (San $m.MSGV1) (San $m.MSGV2) (San $m.MSGV3) (San $m.MSGV4) $lang
                        if (-not $txt) { $txt = "$cls-$no (V1=$(San $m.MSGV1))" }
                        Write-Host ("LOG: kschl={0} sev={1} msg=`"{2}: {3}`"" -f $ks,$sev,"$cls-$no",(Qz $txt))
                        $ev.log += @{ sev=$sev; class=$cls; number=$no; text=$txt }
                    }
                } catch { Write-Host ("LOG: kschl={0} sev=? msg=`"COULD_NOT_CHECK proc-log read failed`"" -f $ks) }
            }
            $evidence.outputs += $ev
        }

        if ($OutJson) { try { $evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutJson -Encoding UTF8; Write-Host "OUT_JSON: $OutJson" } catch { } }
        Write-Host ("STATUS: OK n_outputs=$nOut failed=$nFail notyet=$nNotYet")
        Disconnect-SapRfc
        exit 0
    } catch {
        Write-Host ("ERROR: {0}" -f (San $_.Exception.Message))
        Write-Host "STATUS: RFC_ERROR"
        Disconnect-SapRfc
        exit 2
    }
}
