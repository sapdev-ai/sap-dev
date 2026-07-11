# =============================================================================
# sap_explain_role_rfc.ps1  -  PFCG role extractor for /sap-explain-role (RFC, read-only)
#
# Reads one single or composite role's authorization content over pure RFC and
# writes one TSV per data area (header / tcodes / decoded auths / org levels /
# holders / children) for Claude to narrate into an audit dossier. Every value is
# decoded (auth-object texts TOBJT, activity texts TACTT) so the dossier is prose,
# not code soup. Composite roles are decomposed exactly one level (AGR_AGRS).
#
#   -Role <NAME> [-IncludeHolders] [-Lang <L>] [-MaxRows N] -OutDir <dir>
#
# READ-ONLY. RFC_READ_TABLE only (AGR_*/USR*/TOBJT/TACTT/USORG/TSTCT/USER_ADDR all
# TRANSP/FMODE=R, probed identical S4D + EC2 2026-07-11). PFCG is never driven.
#
# Output (stdout, parseable by SKILL.md):
#   ROLE: name=<n> composite=<Y|N> children=<n> text="<short text>"
#   SECTION: <area> rows=<n> coverage=<CHECKED|COULD_NOT_CHECK> reason=<..>
#   NEAR: <candidate>            (only on ROLE_NOT_FOUND)
#   STATUS: OK | PARTIAL | ROLE_NOT_FOUND | RFC_ERROR
# Exit: 0 OK/PARTIAL | 1 ROLE_NOT_FOUND | 2 RFC/input failure.
# =============================================================================

[CmdletBinding()]
param(
    [string]   $Role = '',
    [switch]   $IncludeHolders,
    [string]   $Lang = '',
    [int]      $MaxRows = 50000,
    [string]   $OutDir = '',
    [string]   $SharedDir = '',
    [string]   $SkillDir = '',
    [string]   $RunId = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
if (-not $SkillDir) { $SkillDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_object_resolver.ps1') { $pp = Join-Path $scripts $lib; if (Test-Path $pp) { . $pp } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function San { param([string] $s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Write-Tsv { param([string] $Path, [string] $Header, [object[]] $Lines)
    $sb = New-Object System.Text.StringBuilder; [void]$sb.AppendLine($Header)
    foreach ($l in $Lines) { [void]$sb.AppendLine($l) }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}

# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {

    if (-not $Role) { Write-Host "STATUS: RFC_ERROR reason=no_role"; exit 2 }
    if (-not $OutDir) { Write-Host "STATUS: RFC_ERROR reason=no_outdir"; exit 2 }
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $roleU = (San $Role).ToUpper()

    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_ROLE"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }

    # AGR_1251 reader (DELETED-tombstones excluded; capped at -MaxRows). A single
    # role's live auth-value set is well under the default 50000 cap; hitting it is
    # reported as PARTIAL/COULD_NOT_CHECK, never silently truncated.
    function Read-Auths {
        param([string] $agr)
        $rows = Read-SapTableRows -Destination $g_dest -Table 'AGR_1251' -Where "AGR_NAME EQ '$agr' AND DELETED NE 'X'" -Fields @('OBJECT','AUTH','FIELD','LOW','HIGH') -RowCount $MaxRows
        return @($rows)
    }

    try {
        # ---- header (AGR_DEFINE) -----------------------------------------
        $def = Read-SapTableRows -Destination $g_dest -Table 'AGR_DEFINE' -Where "AGR_NAME EQ '$roleU'" -Fields @('AGR_NAME','CREATE_USR','CREATE_DAT','CHANGE_USR','CHANGE_DAT') -RowCount 1
        if (-not @($def).Count) {
            Write-Host "STATUS: ROLE_NOT_FOUND"
            $prefix = if ($roleU.Length -ge 3) { $roleU.Substring(0, [Math]::Min(10,$roleU.Length)) } else { $roleU }
            try { $near = Read-SapTableRows -Destination $g_dest -Table 'AGR_DEFINE' -Where "AGR_NAME LIKE '$prefix%'" -Fields @('AGR_NAME') -RowCount 10; foreach ($x in @($near)) { Write-Host ("NEAR: {0}" -f (San $x.AGR_NAME)) } } catch { }
            Disconnect-SapRfc; exit 1
        }
        $h = $def[0]
        # role text: prefer line 00000, logon lang else any
        $txt = ''
        try { $tr = Read-SapTableRows -Destination $g_dest -Table 'AGR_TEXTS' -Where "AGR_NAME EQ '$roleU' AND LINE EQ '00000'" -Fields @('SPRAS','TEXT') -RowCount 10; if (@($tr).Count) { $txt = San $tr[0].TEXT } } catch { }

        # ---- composite children (AGR_AGRS) -------------------------------
        $children = @()
        try { $ch = Read-SapTableRows -Destination $g_dest -Table 'AGR_AGRS' -Where "AGR_NAME EQ '$roleU'" -Fields @('CHILD_AGR') -RowCount 500; foreach ($x in @($ch)) { $cn = San $x.CHILD_AGR; if ($cn) { $children += $cn } } } catch { }
        $isComposite = ($children.Count -gt 0)
        Write-Host ("ROLE: name={0} composite={1} children={2} text=`"{3}`"" -f $roleU,$(if($isComposite){'Y'}else{'N'}),$children.Count,($txt -replace '"',"'"))
        $compFlag = if ($isComposite) { 'Y' } else { 'N' }
        $hdrRow = ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $roleU,(San $h.CREATE_USR),(San $h.CREATE_DAT),(San $h.CHANGE_USR),(San $h.CHANGE_DAT),$compFlag,($txt -replace "`t",' '))
        Write-Tsv (Join-Path $OutDir 'role_header.tsv') "agr_name`tcreate_usr`tcreate_dat`tchange_usr`tchange_dat`tcomposite`ttext" @($hdrRow)
        if ($isComposite) { Write-Tsv (Join-Path $OutDir 'role_children.tsv') "child_agr" (@($children)); Write-Host ("SECTION: children rows={0} coverage=CHECKED" -f $children.Count) }

        # roles to extract auth/tcode content from (self, or all children if composite)
        $srcRoles = if ($isComposite) { $children } else { @($roleU) }

        # ---- transactions (AGR_TCODES TYPE=TC) + S_TCODE from auths -------
        $tcodes = @{}
        foreach ($sr in $srcRoles) {
            try { $tc = Read-SapTableRows -Destination $g_dest -Table 'AGR_TCODES' -Where "AGR_NAME EQ '$sr'" -Fields @('TCODE','TYPE','EXCLUDE') -RowCount 2000; foreach ($x in @($tc)) { $t = San $x.TCODE; $ty = San $x.TYPE; if ($t -and (San $x.EXCLUDE) -ne 'X' -and $ty -ne 'FO') { if (-not $tcodes.ContainsKey($t)) { $tcodes[$t] = 'menu' } } } } catch { }
        }

        # ---- decoded auth values (paged) ---------------------------------
        $authRows = @(); $authCapped = $false
        foreach ($sr in $srcRoles) { $a = Read-Auths $sr; $authRows += @($a) | ForEach-Object { $_ | Add-Member -NotePropertyName _src -NotePropertyValue $sr -PassThru }; if ($authRows.Count -ge $MaxRows) { $authCapped = $true; break } }
        # collect S_TCODE grants (add to tcode set as 'grant')
        foreach ($r in @($authRows)) { if ((San $r.OBJECT) -eq 'S_TCODE' -and (San $r.FIELD) -eq 'TCD') { $tv = San $r.LOW; if ($tv) { if ($tcodes.ContainsKey($tv)) { $tcodes[$tv] = 'menu+grant' } else { $tcodes[$tv] = 'grant' } } } }

        # decode maps: TACTT once (small); TOBJT per distinct object (prefer 'E')
        $actMap = @{}
        try { $ta = Read-SapTableRows -Destination $g_dest -Table 'TACTT' -Fields @('SPRAS','ACTVT','LTEXT') -RowCount 2000; foreach ($x in @($ta)) { $av = San $x.ACTVT; $lg = San $x.SPRAS; if ($av -and (-not $actMap.ContainsKey($av) -or $lg -eq 'E')) { $actMap[$av] = San $x.LTEXT } } } catch { }
        $objMap = @{}
        $distinctObj = @($authRows | ForEach-Object { San $_.OBJECT } | Sort-Object -Unique) | Where-Object { $_ }
        foreach ($ob in $distinctObj) {
            $esc = $ob -replace "'", "''"
            try { $ot = Read-SapTableRows -Destination $g_dest -Table 'TOBJT' -Where "OBJECT EQ '$esc'" -Fields @('LANGU','TTEXT') -RowCount 20; $pick=''; foreach ($x in @($ot)) { $lg=San $x.LANGU; if ($lg -eq 'E') { $pick = San $x.TTEXT; break }; if (-not $pick) { $pick = San $x.TTEXT } }; $objMap[$ob] = $pick } catch { $objMap[$ob] = '' }
        }

        # write decoded auths
        $aLines = @()
        foreach ($r in @($authRows)) {
            $ob = San $r.OBJECT; $fld = San $r.FIELD; $low = San $r.LOW; $high = San $r.HIGH
            $otext = $objMap[$ob]
            $vtext = if ($fld -eq 'ACTVT' -and $actMap.ContainsKey($low)) { $actMap[$low] } else { '' }
            $aLines += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f (San $r._src),$ob,($otext -replace "`t",' '),(San $r.AUTH),$fld,$low,$high,($vtext -replace "`t",' '))
        }
        Write-Tsv (Join-Path $OutDir 'role_auths_decoded.tsv') "src_role`tobject`tobject_text`tauth`tfield`tlow`thigh`tactivity_text" $aLines
        Write-Host ("SECTION: auths rows={0} coverage={1}{2}" -f $authRows.Count,$(if($authCapped){'COULD_NOT_CHECK'}else{'CHECKED'}),$(if($authCapped){" reason=truncated_at_$MaxRows"}else{''}))

        # tcodes TSV (+ text via TSTCT per-tcode, capped 200)
        $tcLines = @(); $tcSet = @($tcodes.Keys | Sort-Object); $tcDecoded = 0
        foreach ($t in $tcSet) {
            $ttext = ''
            if ($tcDecoded -lt 200) { $tcDecoded++; try { $esc=$t -replace "'","''"; $tt = Read-SapTableRows -Destination $g_dest -Table 'TSTCT' -Where "TCODE EQ '$esc'" -Fields @('SPRSL','TTEXT') -RowCount 10; foreach ($x in @($tt)) { $lg=San $x.SPRSL; if ($lg -eq 'E') { $ttext=San $x.TTEXT; break }; if (-not $ttext) { $ttext=San $x.TTEXT } } } catch { } }
            $tcLines += ("{0}`t{1}`t{2}" -f $t,$tcodes[$t],($ttext -replace "`t",' '))
        }
        Write-Tsv (Join-Path $OutDir 'role_tcodes.tsv') "tcode`tsource`ttext" $tcLines
        Write-Host ("SECTION: tcodes rows={0} coverage=CHECKED" -f $tcSet.Count)

        # ---- org levels (AGR_1252 x USORG) -------------------------------
        $usorg = @{}
        try { $uo = Read-SapTableRows -Destination $g_dest -Table 'USORG' -Fields @('VARBL','FIELD') -RowCount 500; foreach ($x in @($uo)) { $v=San $x.VARBL; if ($v) { $usorg[$v] = San $x.FIELD } } } catch { }
        $olLines = @(); $olN = 0
        foreach ($sr in $srcRoles) {
            try { $ol = Read-SapTableRows -Destination $g_dest -Table 'AGR_1252' -Where "AGR_NAME EQ '$sr'" -Fields @('VARBL','LOW','HIGH') -RowCount 2000; foreach ($x in @($ol)) { $v=San $x.VARBL; if ($v) { $olN++; $olLines += ("{0}`t{1}`t{2}`t{3}`t{4}" -f $sr,$v,$(if($usorg.ContainsKey($v)){$usorg[$v]}else{''}),(San $x.LOW),(San $x.HIGH)) } } } catch { }
        }
        Write-Tsv (Join-Path $OutDir 'role_orglevels.tsv') "src_role`tvarbl`torg_field`tlow`thigh" $olLines
        Write-Host ("SECTION: orglevels rows={0} coverage=CHECKED" -f $olN)

        # ---- holders (AGR_USERS x USR02 x USER_ADDR) ---------------------
        if ($IncludeHolders) {
            $hoLines = @(); $hoN = 0; $hoCov = 'CHECKED'
            try {
                $hu = Read-SapTableRows -Destination $g_dest -Table 'AGR_USERS' -Where "AGR_NAME EQ '$roleU'" -Fields @('UNAME','FROM_DAT','TO_DAT') -RowCount 5000
                foreach ($x in @($hu)) {
                    $u = San $x.UNAME; if (-not $u) { continue }; $hoN++
                    $lock=''; $vfrom=''; $vto=''; $nm=''
                    try { $u2 = Read-SapTableRows -Destination $g_dest -Table 'USR02' -Where "BNAME EQ '$($u -replace "'","''")'" -Fields @('UFLAG','GLTGV','GLTGB') -RowCount 1; if (@($u2).Count) { $lock=(San $u2[0].UFLAG); $vfrom=(San $u2[0].GLTGV); $vto=(San $u2[0].GLTGB) } } catch { }
                    try { $ua = Read-SapTableRows -Destination $g_dest -Table 'USER_ADDR' -Where "BNAME EQ '$($u -replace "'","''")'" -Fields @('NAME_TEXTC') -RowCount 1; if (@($ua).Count) { $nm=(San $ua[0].NAME_TEXTC) } } catch { }
                    $locked = if ($lock -and $lock -ne '0') { 'Y' } else { 'N' }
                    $hoLines += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f $u,($nm -replace "`t",' '),$locked,(San $x.FROM_DAT),(San $x.TO_DAT),"uflag=$lock user_valid=$vfrom..$vto")
                }
            } catch { $hoCov = 'COULD_NOT_CHECK' }
            Write-Tsv (Join-Path $OutDir 'role_holders.tsv') "uname`tname`tlocked`trole_from`trole_to`tnote" $hoLines
            Write-Host ("SECTION: holders rows={0} coverage={1}" -f $hoN,$hoCov)
        } else { Write-Host "SECTION: holders rows=0 coverage=CHECKED reason=--no-holders" }

        Write-Host ("STATUS: {0}" -f $(if($authCapped){'PARTIAL'}else{'OK'}))
        Disconnect-SapRfc; exit 0
    } catch {
        Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host "STATUS: RFC_ERROR"; Disconnect-SapRfc; exit 2
    }
}
